-- | Bracket a single isolated clone of a sealed baseline.
module Hinagata.Postgres.Lease
  ( LeaseInfo (..),
    LeaseError (..),
    withDatabase,
  )
where

import Control.Exception (IOException, SomeException, mask, throwIO, try)
import Data.Bifunctor (first)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import Hinagata.Config
import Hinagata.Connection (ConnectionTarget)
import Hinagata.Fixture.Bundle
import Hinagata.Postgres.Error (NativeError (..), NativePhase (..), SessionError)
import Hinagata.Postgres.Internal.Access qualified as Access
import Hinagata.Postgres.Internal.BaselineRef
import Hinagata.Postgres.Internal.Libpq
import Hinagata.Postgres.Internal.Load (loadComposedRemainder)
import Hinagata.Postgres.Ownership
import Hinagata.Prelude
import Hinagata.Types
import Text.Read (readMaybe)

-- | Application credentials are held only in the target. Its Show instance
-- redacts the password; maintenance credentials never leave this module.
data LeaseInfo = LeaseInfo
  { leaseId :: !Text,
    runId :: !Text,
    applicationTarget :: !ConnectionTarget
  }
  deriving stock (Eq, Show)

-- | A lifecycle failure, distinct from a consumer callback's exception.
data LeaseError = LeaseError
  { cause :: !Text,
    sqlState :: !(Maybe Text),
    cleanupFailure :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data Clone = Clone
  { allocationId :: !Text,
    cloneLeaseId :: !Text,
    cloneRunId :: !Text,
    owned :: !OwnedDatabase
  }

-- | Allocate, load, hand off, and release one clone. The callback must close
-- its own pools and connections before returning. A failed setup or thrown
-- callback still attempts bounded, ownership-checked release. Ambiguous
-- allocations remain in the catalog for explicit recovery.
withDatabase :: HinagataConfig -> BaselineRef -> FixturePlan -> (LeaseInfo -> IO a) -> IO (Either LeaseError a)
withDatabase configuration baseline scenario callback = do
  case composePlans (baselinePlan baseline) scenario of
    Left _ -> pure (Left (failure "scenario conflicts with the frozen baseline"))
    Right composed -> do
      verified <- try @IOException (verifyPlan scenario)
      case verified of
        Left _ -> pure (Left (failure "scenario bundle could not be verified"))
        Right False -> pure (Left (failure "scenario bundle changed"))
        Right True -> start composed
  where
    options = defaultSessionOptions {operationDeadlineMs = positiveValue (acquisitionDeadlineMs configuration)}
    maintenance = first accessFailure (Access.adminTarget configuration (maintenanceDatabase configuration))

    start composed = case maintenance of
      Left problem -> pure (Left problem)
      Right target -> do
        catalog <- ensureCatalog target (maintenanceSchema configuration) options
        case catalog of
          Left CatalogError {cause, sqlState} -> pure (Left (LeaseError cause sqlState Nothing))
          Right identity
            | identity /= clusterIdentity baseline -> pure (Left (failure "baseline belongs to a different catalog or cluster"))
            | otherwise -> do
                opened <- withSession target options $ \session -> mask $ \restore -> do
                  acquired <- restore (allocate configuration baseline session target options identity)
                  case acquired of
                    Left problem -> pure (Left problem)
                    Right clone -> do
                      outcome <- try @SomeException (restore (prepareAndUse session clone composed))
                      cleaned <- try @SomeException (release configuration session target options identity clone)
                      case outcome of
                        Left exception -> throwIO exception
                        Right result -> pure (mergeCleanup result cleaned)
                pure $ case opened of
                  Left problem -> Left (sessionFailure problem)
                  Right result -> result

    prepareAndUse session clone composed = do
      let OwnedDatabase {name = database} = owned clone
      prepared <- runExclusive session $ \connection sessionOptions -> do
        deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
        result <- Access.prepareAccess connection sessionOptions configuration database deadline
        pure (Keep (first accessFailure result))
      case flatten prepared of
        Left problem -> pure (Left problem)
        Right () -> case first accessFailure (Access.accessToTarget configuration (setup configuration) database) of
          Left problem -> pure (Left problem)
          Right setupTarget -> do
            loaded <- withSession setupTarget options (\setupSession -> loadComposedRemainder setupSession scenario composed)
            case loaded of
              Left problem -> pure (Left (sessionFailure problem))
              Right (Left _) -> pure (Left (failure "scenario fixture load failed"))
              Right (Right _) -> do
                active <- markState configuration session clone "Active"
                case active of
                  Left problem -> pure (Left problem)
                  Right () -> case first accessFailure (Access.accessToTarget configuration (application configuration) database) of
                    Left problem -> pure (Left problem)
                    Right appTarget -> Right <$> callback LeaseInfo {leaseId = cloneLeaseId clone, runId = cloneRunId clone, applicationTarget = appTarget}

allocate :: HinagataConfig -> BaselineRef -> Session -> ConnectionTarget -> SessionOptions -> CatalogIdentity -> IO (Either LeaseError Clone)
allocate configuration baseline session maintenance options identity = do
  acquired <- runExclusive session $ \connection sessionOptions -> do
    deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
    let lockKey = generationLockKey baseline
    locked <- queryParamRows connection deadline Sql "SELECT pg_advisory_lock_shared(1212761905, hashtext($1))" [Just (Encoding.encodeUtf8 lockKey)] 1
    case locked of
      Left problem -> pure (Keep (Left (nativeFailure problem)))
      Right _ -> do
        let generations = quoteSqlIdentifier (maintenanceSchema configuration) <> ".\"generations\""
            statement = Encoding.encodeUtf8 ("SELECT database_name::text, database_oid::text, ownership_token::text, state FROM " <> generations <> " WHERE id = $1 AND project_id = $2")
            args = map (Just . Encoding.encodeUtf8) [generationId baseline, projectIdText (project configuration)]
        rows <- queryParamRows connection deadline Sql statement args 1
        case rows of
          Left problem -> pure (Keep (Left (nativeFailure problem)))
          Right [[Just database, Just oidBytes, Just tokenBytes, Just "Ready"]]
            | database == Encoding.encodeUtf8 (databaseNameText (baselineName baseline))
                && oidBytes == Encoding.encodeUtf8 (Text.pack (show (oid (ownership baseline))))
                && tokenBytes == Encoding.encodeUtf8 (token (ownership baseline)) -> do
                sealed <- queryParamRows connection deadline Sql "SELECT datallowconn::text FROM pg_database WHERE datname = $1" [Just database] 1
                pure (Keep (case sealed of Right [[Just "false"]] -> Right (); Left problem -> Left (nativeFailure problem); _ -> Left (failure "baseline is not sealed")))
          Right _ -> pure (Keep (Left (failure "baseline generation is no longer ready or has changed identity")))
  case flatten acquired of
    Left problem -> pure (Left problem)
    Right () -> do
      evidence <- verifyOwnedDatabase maintenance options identity (ownership baseline)
      case evidence of
        Right OwnershipMatches -> flatten <$> runExclusive session (\connection sessionOptions -> Keep <$> createClone configuration baseline connection sessionOptions identity)
        Right _ -> pure (Left (failure "baseline lost positive ownership"))
        Left CatalogError {cause, sqlState} -> pure (Left (LeaseError cause sqlState Nothing))

createClone :: HinagataConfig -> BaselineRef -> PQ.Connection -> SessionOptions -> CatalogIdentity -> IO (Either LeaseError Clone)
createClone configuration baseline connection sessionOptions identity = do
  deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
  ids <- queryParamRows connection deadline Sql "SELECT gen_random_uuid()::text, gen_random_uuid()::text, gen_random_uuid()::text, gen_random_uuid()::text" [] 1
  case ids of
    Right [[Just allocationBytes, Just leaseBytes, Just runBytes, Just tokenBytes]] -> do
      let allocation = Encoding.decodeUtf8 allocationBytes
          lease = Encoding.decodeUtf8 leaseBytes
          run = Encoding.decodeUtf8 runBytes
          tokenText = Encoding.decodeUtf8 tokenBytes
          databaseText = "hl_" <> Text.take 8 (baselineFingerprint baseline) <> "_" <> Text.take 20 (Text.filter (/= '-') tokenText)
      case mkDatabaseName databaseText of
        Left _ -> pure (Left (failure "generated clone name is invalid"))
        Right database -> do
          let table = quoteSqlIdentifier (maintenanceSchema configuration) <> ".\"allocations\""
              insertSql = Encoding.encodeUtf8 ("INSERT INTO " <> table <> " (id, project_id, generation_id, run_id, database_name, ownership_token, state) VALUES ($1, $2, $3, $4, $5, $6::uuid, 'Allocating')")
              args = map (Just . Encoding.encodeUtf8) [allocation, projectIdText (project configuration), generationId baseline, run, databaseText, tokenText]
          inserted <- queryParamRows connection deadline Sql insertSql args 0
          case inserted of
            Left problem -> pure (Left (nativeFailure problem))
            Right _ -> do
              let strategy = case cloneStrategy configuration of WalLog -> "WAL_LOG"; FileCopy -> "FILE_COPY"
                  quoted = Access.quoteDatabase database
                  createSql = Encoding.encodeUtf8 ("CREATE DATABASE " <> quoted <> " TEMPLATE " <> Access.quoteDatabase (baselineName baseline) <> " STRATEGY " <> strategy <> " ALLOW_CONNECTIONS true")
              created <- query connection deadline Sql createSql
              case created of
                Left problem -> pure (Left (nativeFailure problem))
                Right () -> do
                  let marker = "hinagata:v1:" <> clusterUuid identity <> ":" <> tokenText
                  commented <- query connection deadline Sql (Encoding.encodeUtf8 ("COMMENT ON DATABASE " <> quoted <> " IS " <> Access.quoteLiteral marker))
                  case commented of
                    Left problem -> pure (Left (nativeFailure problem))
                    Right () -> do
                      observed <- queryParamRows connection deadline Sql "SELECT oid::text FROM pg_database WHERE datname = $1" [Just (Encoding.encodeUtf8 databaseText)] 1
                      case observed of
                        Right [[Just numberBytes]] -> case readMaybe (Text.unpack (Encoding.decodeUtf8 numberBytes)) of
                          Nothing -> pure (Left (failure "clone has an invalid OID"))
                          Just number -> do
                            let bindSql = Encoding.encodeUtf8 ("UPDATE " <> table <> " SET database_oid = $2::oid, state = 'Loading', updated_at = clock_timestamp() WHERE id = $1 AND state = 'Allocating' RETURNING id")
                            bound <- queryParamRows connection deadline Sql bindSql [Just allocationBytes, Just numberBytes] 1
                            case bound of
                              Right [[Just _]] -> do
                                let leases = quoteSqlIdentifier (maintenanceSchema configuration) <> ".\"leases\""
                                    leaseSql = Encoding.encodeUtf8 ("INSERT INTO " <> leases <> " (id, allocation_id, run_id, state) VALUES ($1, $2, $3, 'Loading')")
                                recorded <- queryParamRows connection deadline Sql leaseSql (map Just [leaseBytes, allocationBytes, runBytes]) 0
                                case recorded of
                                  Left problem -> pure (Left (nativeFailure problem))
                                  Right _ -> do
                                    let leaseKey = leaseLockKey lease
                                    guarded <- queryParamRows connection deadline Sql "SELECT pg_advisory_lock(1212761905, hashtext($1))" [Just (Encoding.encodeUtf8 leaseKey)] 1
                                    case guarded of
                                      Left problem -> pure (Left (nativeFailure problem))
                                      Right _ -> do
                                        unlocked <- queryParamRows connection deadline Sql "SELECT pg_advisory_unlock_shared(1212761905, hashtext($1))::text" [Just (Encoding.encodeUtf8 (generationLockKey baseline))] 1
                                        pure $ case unlocked of
                                          Right [[Just "true"]] -> Right (Clone allocation lease run (OwnedDatabase database number tokenText))
                                          Left problem -> Left (nativeFailure problem)
                                          Right _ -> Left (failure "generation allocation lock could not be released")
                              Left problem -> pure (Left (nativeFailure problem))
                              Right _ -> pure (Left (failure "clone identity could not be bound"))
                        Left problem -> pure (Left (nativeFailure problem))
                        Right _ -> pure (Left (failure "created clone is absent from the catalog"))
    Left problem -> pure (Left (nativeFailure problem))
    Right _ -> pure (Left (failure "clone UUID generation returned an invalid result"))

markState :: HinagataConfig -> Session -> Clone -> Text -> IO (Either LeaseError ())
markState configuration session clone state =
  flatten
    <$> runExclusive
      session
      ( \connection options -> do
          deadline <- deadlineAfter (operationDeadlineMs options)
          let schema = quoteSqlIdentifier (maintenanceSchema configuration)
              allocationSql = Encoding.encodeUtf8 ("UPDATE " <> schema <> ".\"allocations\" SET state = $2, updated_at = clock_timestamp() WHERE id = $1 RETURNING id")
              leaseSql = Encoding.encodeUtf8 ("UPDATE " <> schema <> ".\"leases\" SET state = $2, updated_at = clock_timestamp() WHERE id = $1 RETURNING id")
              update statement identifier = queryParamRows connection deadline Sql statement (map (Just . Encoding.encodeUtf8) [identifier, state]) 1
              rollback problem = do
                cleanupDeadline <- deadlineAfter (cleanupDeadlineMs options)
                rolled <- query connection cleanupDeadline Rollback "ROLLBACK"
                pure $ case rolled of
                  Right () -> Keep (Left problem)
                  Left _ -> case problem of LeaseError primaryCause primaryState _ -> Retire (Left (LeaseError primaryCause primaryState (Just "catalog state rollback failed")))
          begun <- query connection deadline Begin "BEGIN"
          case begun of
            Left problem -> pure (Retire (Left (nativeFailure problem)))
            Right () -> do
              allocation <- update allocationSql (allocationId clone)
              case allocation of
                Right [[Just _]] -> do
                  lease <- update leaseSql (cloneLeaseId clone)
                  case lease of
                    Right [[Just _]] -> do
                      committed <- query connection deadline Commit "COMMIT"
                      pure $ case committed of
                        Right () -> Keep (Right ())
                        Left problem -> Retire (Left (nativeFailure problem))
                    Left problem -> rollback (nativeFailure problem)
                    Right _ -> rollback (failure "lease state record is missing")
                Left problem -> rollback (nativeFailure problem)
                Right _ -> rollback (failure "allocation state record is missing")
      )

release :: HinagataConfig -> Session -> ConnectionTarget -> SessionOptions -> CatalogIdentity -> Clone -> IO (Either LeaseError ())
release configuration session maintenance options identity clone = do
  evidence <- verifyOwnedDatabase maintenance options identity (owned clone)
  case evidence of
    Left CatalogError {cause, sqlState} -> pure (Left (LeaseError cause sqlState Nothing))
    Right OwnershipMismatch -> pure (Left (failure "clone ownership changed; release refused"))
    Right OwnershipMissing -> markState configuration session clone "Released"
    Right OwnershipMatches -> do
      releasing <- markState configuration session clone "Releasing"
      case releasing of
        Left problem -> pure (Left problem)
        Right () -> do
          dropped <-
            flatten
              <$> runExclusive
                session
                ( \connection sessionOptions -> do
                    deadline <- deadlineAfter (cleanupDeadlineMs sessionOptions)
                    let OwnedDatabase {name = database} = owned clone
                    outcome <- query connection deadline Sql (Encoding.encodeUtf8 ("DROP DATABASE " <> Access.quoteDatabase database <> " WITH (FORCE)"))
                    pure (Keep (first nativeFailure outcome))
                )
          case dropped of
            Left problem -> do
              _ <- markState configuration session clone "CleanupFailed"
              pure (Left problem)
            Right () -> markState configuration session clone "Released"

mergeCleanup :: Either LeaseError a -> Either SomeException (Either LeaseError ()) -> Either LeaseError a
mergeCleanup result cleanup = case cleanup of
  Left _ -> case result of
    Left (LeaseError primaryCause primaryState _) -> Left (LeaseError primaryCause primaryState (Just "clone release raised an exception"))
    Right _ -> Left (failure "clone release raised an exception")
  Right (Left problem@LeaseError {cause = cleanupCause}) -> case result of
    Left (LeaseError primaryCause primaryState _) -> Left (LeaseError primaryCause primaryState (Just cleanupCause))
    Right _ -> Left problem
  Right (Right ()) -> result

flatten :: Either SessionError (Either LeaseError a) -> Either LeaseError a
flatten = either (Left . sessionFailure) id

failure :: Text -> LeaseError
failure cause = LeaseError cause Nothing Nothing

nativeFailure :: NativeError -> LeaseError
nativeFailure NativeError {reason, sqlState} = LeaseError reason sqlState Nothing

accessFailure :: Access.AccessError -> LeaseError
accessFailure Access.AccessError {cause, sqlState} = LeaseError cause sqlState Nothing

sessionFailure :: SessionError -> LeaseError
sessionFailure problem = failure (Text.pack (show problem))

generationLockKey :: BaselineRef -> Text
generationLockKey baseline = "generation:" <> generationId baseline

leaseLockKey :: Text -> Text
leaseLockKey lease = "lease:" <> lease
