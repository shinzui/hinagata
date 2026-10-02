-- | Build and reuse immutable PostgreSQL template generations.
module Hinagata.Postgres.Baseline
  ( BaselineSpec (..),
    BaselineRef,
    baselineDatabase,
    PreparationKind (..),
    FingerprintComponent (..),
    fingerprintComponents,
    FingerprintComparison (..),
    PreparationReport (..),
    BaselineError (..),
    ensureBaseline,
    retireBaseline,
  )
where

import Control.Exception (IOException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import GHC.Clock (getMonotonicTimeNSec)
import Hinagata.Config
import Hinagata.Connection
import Hinagata.Fixture.Bundle
import Hinagata.Postgres.Error (NativeError (..), NativePhase (..), SessionError (..))
import Hinagata.Postgres.Internal.Access qualified as Access
import Hinagata.Postgres.Internal.BaselineRef
import Hinagata.Postgres.Internal.Libpq
import Hinagata.Postgres.Load (loadInto)
import Hinagata.Postgres.Ownership
import Hinagata.Prelude
import Hinagata.Types
import Numeric (showHex)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | Hooks must close their own database connections before returning.
-- Missing migration or verification revisions force a new generation on every
-- call. Clone preparation runs on each fresh clone before scenario loading.
data BaselineSpec = BaselineSpec
  { configuration :: !HinagataConfig,
    basePlan :: !FixturePlan,
    migrationRevision :: !(Maybe Text),
    verificationRevision :: !(Maybe Text),
    requiredExtensions :: ![Text],
    requiredLocale :: !(Maybe Text),
    migrationHook :: !(ConnectionTarget -> IO (Either Text ())),
    verificationHook :: !(ConnectionTarget -> IO (Either Text ())),
    clonePreparationHook :: !(Maybe (ConnectionTarget -> IO (Either Text ()))),
    compareAgainst :: !(Maybe BaselineRef)
  }

-- | Name of the sealed template database. Consumers should acquire a clone
-- through the lease API instead of connecting to this database.
baselineDatabase :: BaselineRef -> DatabaseName
baselineDatabase BaselineRef {baselineName} = baselineName

-- | Whether this call published a new generation or reused a ready one.
data PreparationKind = Built | Reused
  deriving stock (Eq, Show)

-- | Non-secret categories in the versioned fingerprint manifest.
data FingerprintComponent
  = FingerprintVersion
  | ServerMajor
  | ProjectIdentity
  | BaseFixtures
  | MigrationRevision
  | VerificationRevision
  | ExtensionRequirements
  | LocaleRequirement
  | AdministrationRole
  | SetupRole
  | ApplicationRole
  | SetupPrivileges
  | ApplicationPrivileges
  | SetupSchemaPrivileges
  | ApplicationSchemaPrivileges
  | SetupRoleSettings
  | ApplicationRoleSettings
  deriving stock (Eq, Show)

-- | Changes against the caller's explicitly selected prior generation.
data FingerprintComparison = FingerprintComparison
  { previousFingerprint :: !Text,
    changedComponents :: ![FingerprintComponent]
  }
  deriving stock (Eq, Show)

-- | Build/reuse report. The duration includes hook and fixture work. No
-- comparison is claimed unless the caller selected a prior generation.
data PreparationReport = PreparationReport
  { kind :: !PreparationKind,
    fingerprint :: !Text,
    elapsedMs :: !Int,
    comparison :: !(Maybe FingerprintComparison)
  }
  deriving stock (Eq, Show)

-- | Non-secret operational failure. An incomplete generation remains recorded
-- for explicit inspection instead of being guessed safe to delete.
data BaselineError = BaselineError
  { cause :: !Text,
    sqlState :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | Verify a frozen base plan, then reuse a positively identified sealed
-- generation or build one from @template0@. A failed build leaves its record
-- inspectable and never replaces an earlier ready generation. The caller owns
-- migration and verification hooks and must close their connections before
-- returning; unexpected hook exceptions propagate after the admin session
-- closes.
ensureBaseline :: BaselineSpec -> IO (Either BaselineError (BaselineRef, PreparationReport))
ensureBaseline spec@BaselineSpec {configuration} = do
  start <- getMonotonicTimeNSec
  verified <- try @IOException (verifyPlan (basePlan spec))
  case verified of
    Left _ -> pure (Left (BaselineError "base fixture bundle could not be verified" Nothing))
    Right False -> pure (Left (BaselineError "base fixture bundle changed" Nothing))
    Right True -> startCatalog start
  where
    startCatalog start = case first accessFailure (Access.adminTarget configuration (maintenanceDatabase configuration)) of
      Left failure -> pure (Left failure)
      Right maintenance -> do
        let options = defaultSessionOptions {operationDeadlineMs = positiveValue (setupDeadlineMs configuration)}
        catalog <- ensureCatalog maintenance (maintenanceSchema configuration) options
        case catalog of
          Left CatalogError {cause, sqlState} -> pure (Left (BaselineError cause sqlState))
          Right identity -> do
            opened <- withSession maintenance options $ \session ->
              runExclusive session $ \connection sessionOptions -> do
                outcome <- prepare connection maintenance sessionOptions identity spec
                pure (Keep outcome)
            end <- getMonotonicTimeNSec
            pure $ case opened of
              Left failure -> Left (sessionFailure failure)
              Right (Left failure) -> Left (sessionFailure failure)
              Right (Right (Right (baseline, kind, comparison))) -> Right (baseline, PreparationReport kind (baselineFingerprint baseline) (fromIntegral ((end - start) `div` 1000000)) comparison)
              Right (Right (Left failure)) -> Left failure

-- | Retire a positively identified sealed generation under its exclusive
-- generation lock. Existing clones remain independent; the Retiring catalog
-- record is kept as a tombstone for their allocation references. A retry is
-- idempotent after the owned template has already disappeared.
retireBaseline :: HinagataConfig -> BaselineRef -> IO (Either BaselineError ())
retireBaseline configuration baseline =
  case first accessFailure (Access.adminTarget configuration (maintenanceDatabase configuration)) of
    Left problem -> pure (Left problem)
    Right maintenance -> do
      let options = defaultSessionOptions {operationDeadlineMs = positiveValue (setupDeadlineMs configuration)}
      catalog <- inspectCatalog maintenance (maintenanceSchema configuration) options
      case catalog of
        Left CatalogError {cause, sqlState} -> pure (Left (BaselineError cause sqlState))
        Right identity
          | identity /= clusterIdentity baseline -> pure (Left (BaselineError "baseline belongs to a different catalog or cluster" Nothing))
          | otherwise -> do
              opened <- withSession maintenance options $ \session ->
                runExclusive session $ \connection sessionOptions -> do
                  deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
                  locked <- queryParamRows connection deadline Sql "SELECT pg_advisory_lock(1212761905, hashtext($1))" [Just (Encoding.encodeUtf8 ("generation:" <> generationId baseline))] 1
                  result <- case locked of
                    Left problem -> pure (Left (nativeFailure problem))
                    Right _ -> retireLocked connection maintenance sessionOptions identity configuration baseline deadline
                  pure (Keep result)
              pure $ case opened of
                Left problem -> Left (sessionFailure problem)
                Right (Left problem) -> Left (sessionFailure problem)
                Right (Right result) -> result

retireLocked :: PQ.Connection -> ConnectionTarget -> SessionOptions -> CatalogIdentity -> HinagataConfig -> BaselineRef -> Deadline -> IO (Either BaselineError ())
retireLocked connection maintenance options identity configuration baseline deadline = do
  let table = quoteSqlIdentifier (maintenanceSchema configuration) <> ".\"generations\""
      statement = Encoding.encodeUtf8 ("SELECT database_name::text, database_oid::text, ownership_token::text, state FROM " <> table <> " WHERE id = $1 AND project_id = $2")
      args = map (Just . Encoding.encodeUtf8) [generationId baseline, projectIdText (project configuration)]
  rows <- queryParamRows connection deadline Sql statement args 1
  case rows of
    Left problem -> pure (Left (nativeFailure problem))
    Right [[Just database, Just oidBytes, Just tokenBytes, Just state]]
      | database == Encoding.encodeUtf8 (databaseNameText (baselineName baseline))
          && oidBytes == Encoding.encodeUtf8 (Text.pack (show (oid (ownership baseline))))
          && tokenBytes == Encoding.encodeUtf8 (token (ownership baseline))
          && state `elem` ["Ready", "Retiring"] -> do
          evidence <- verifyOwnedDatabase maintenance options identity (ownership baseline)
          case evidence of
            Left CatalogError {cause, sqlState} -> pure (Left (BaselineError cause sqlState))
            Right OwnershipMismatch -> pure (Left (BaselineError "baseline ownership changed; retirement refused" Nothing))
            Right OwnershipMissing
              | state == "Retiring" -> pure (Right ())
              | otherwise -> pure (Left (BaselineError "ready baseline is missing; retirement refused" Nothing))
            Right OwnershipMatches -> do
              marked <- if state == "Retiring" then pure (Right []) else queryParamRows connection deadline Sql (Encoding.encodeUtf8 ("UPDATE " <> table <> " SET state = 'Retiring', updated_at = clock_timestamp() WHERE id = $1 AND state = 'Ready' RETURNING id")) [Just (Encoding.encodeUtf8 (generationId baseline))] 1
              case marked of
                Left problem -> pure (Left (nativeFailure problem))
                Right [[Just _]] | state == "Ready" -> dropTemplate connection options baseline
                Right [] | state == "Retiring" -> dropTemplate connection options baseline
                Right _ -> pure (Left (BaselineError "baseline state changed during retirement" Nothing))
    Right _ -> pure (Left (BaselineError "baseline generation is missing or has changed identity" Nothing))

dropTemplate :: PQ.Connection -> SessionOptions -> BaselineRef -> IO (Either BaselineError ())
dropTemplate connection options baseline = do
  deadline <- deadlineAfter (cleanupDeadlineMs options)
  outcome <- query connection deadline Sql (Encoding.encodeUtf8 ("DROP DATABASE " <> Access.quoteDatabase (baselineName baseline) <> " WITH (FORCE)"))
  pure (first nativeFailure outcome)

prepare :: PQ.Connection -> ConnectionTarget -> SessionOptions -> CatalogIdentity -> BaselineSpec -> IO (Either BaselineError (BaselineRef, PreparationKind, Maybe FingerprintComparison))
prepare connection maintenance options identity spec@BaselineSpec {configuration, basePlan, migrationRevision, verificationRevision} = do
  server <- PQ.serverVersion connection
  let manifest = fingerprintManifest server spec
      digest = hex (SHA256.hash (Encoding.encodeUtf8 manifest))
      projectText = projectIdText (project configuration)
      lockName = projectText <> ":" <> digest
      reusable = isJust migrationRevision && isJust verificationRevision
  deadline <- deadlineAfter (operationDeadlineMs options)
  compared <- comparePrevious connection configuration identity (compareAgainst spec) manifest deadline
  case compared of
    Left failure -> pure (Left failure)
    Right comparison -> do
      locked <- queryParamRows connection deadline Sql "SELECT pg_advisory_lock(1212761905, hashtext($1))" [Just (Encoding.encodeUtf8 lockName)] 1
      case locked of
        Left failure -> pure (Left (nativeFailure failure))
        Right _ -> prepareLocked comparison connection maintenance options identity configuration basePlan projectText digest manifest spec reusable deadline

prepareLocked :: Maybe FingerprintComparison -> PQ.Connection -> ConnectionTarget -> SessionOptions -> CatalogIdentity -> HinagataConfig -> FixturePlan -> Text -> Text -> Text -> BaselineSpec -> Bool -> Deadline -> IO (Either BaselineError (BaselineRef, PreparationKind, Maybe FingerprintComparison))
prepareLocked comparison connection maintenance options identity configuration basePlan projectText digest manifest spec reusable deadline = do
  let table = quoteSqlIdentifier (maintenanceSchema configuration) <> ".\"generations\""
      interruptedSql = Encoding.encodeUtf8 ("UPDATE " <> table <> " SET state = 'Failed', last_error = 'builder session ended before publication', updated_at = clock_timestamp() WHERE project_id = $1 AND fingerprint = $2 AND state = 'Building'")
      interruptedArgs = map (Just . Encoding.encodeUtf8) [projectText, digest]
  interrupted <- queryParamRows connection deadline Sql interruptedSql interruptedArgs 0
  case interrupted of
    Left failure -> pure (Left (nativeFailure failure))
    Right _ -> do
      previous <- if reusable then lookupReady connection configuration basePlan (clonePreparationHook spec) deadline projectText digest else pure (Right Nothing)
      case previous of
        Left failure -> pure (Left failure)
        Right (Just baseline) -> do
          evidence <- verifyOwnedDatabase maintenance options identity (ownership baseline)
          case evidence of
            Right OwnershipMatches -> do
              sealed <- queryParamRows connection deadline Sql "SELECT datallowconn::text FROM pg_database WHERE datname = $1" [Just (Encoding.encodeUtf8 (databaseNameText (baselineDatabase baseline)))] 1
              pure $ case sealed of
                Right [[Just "false"]] -> Right (baseline {clusterIdentity = identity}, Reused, comparison)
                Right _ -> Left (BaselineError "ready generation is not sealed" Nothing)
                Left failure -> Left (nativeFailure failure)
            Right _ -> pure (Left (BaselineError "ready generation lost positive database ownership" Nothing))
            Left CatalogError {cause, sqlState} -> pure (Left (BaselineError cause sqlState))
        Right Nothing -> fmap (fmap (\(baseline, kind) -> (baseline, kind, comparison))) (buildGeneration connection maintenance options identity configuration basePlan projectText digest manifest spec deadline)

comparePrevious :: PQ.Connection -> HinagataConfig -> CatalogIdentity -> Maybe BaselineRef -> Text -> Deadline -> IO (Either BaselineError (Maybe FingerprintComparison))
comparePrevious _ _ _ Nothing _ _ = pure (Right Nothing)
comparePrevious connection configuration identity (Just previous) manifest deadline
  | clusterIdentity previous /= identity = pure (Left (BaselineError "comparison generation belongs to a different catalog or cluster" Nothing))
  | otherwise = do
      let table = quoteSqlIdentifier (maintenanceSchema configuration) <> ".\"generations\""
          statement = Encoding.encodeUtf8 ("SELECT fingerprint::text, fingerprint_manifest->>'manifest' FROM " <> table <> " WHERE id = $1 AND project_id = $2")
          args = map (Just . Encoding.encodeUtf8) [generationId previous, projectIdText (project configuration)]
      rows <- queryParamRows connection deadline Sql statement args 1
      pure $ case rows of
        Left failure -> Left (nativeFailure failure)
        Right [[Just recordedFingerprint, Just recordedManifest]]
          | recordedFingerprint == Encoding.encodeUtf8 (baselineFingerprint previous) ->
              let before = Text.lines (Encoding.decodeUtf8 recordedManifest)
                  after = Text.lines manifest
               in if length before /= length fingerprintComponents || length after /= length fingerprintComponents || listToMaybe before /= Just "hinagata-fingerprint-v1"
                    then Left (BaselineError "comparison generation has an unsupported fingerprint manifest" Nothing)
                    else Right (Just (FingerprintComparison (baselineFingerprint previous) [component | (component, old, new) <- zip3 fingerprintComponents before after, old /= new]))
        Right _ -> Left (BaselineError "comparison generation is missing or has changed fingerprint identity" Nothing)

fingerprintComponents :: [FingerprintComponent]
fingerprintComponents =
  [ FingerprintVersion,
    ServerMajor,
    ProjectIdentity,
    BaseFixtures,
    MigrationRevision,
    VerificationRevision,
    ExtensionRequirements,
    LocaleRequirement,
    AdministrationRole,
    SetupRole,
    ApplicationRole,
    SetupPrivileges,
    ApplicationPrivileges,
    SetupSchemaPrivileges,
    ApplicationSchemaPrivileges,
    SetupRoleSettings,
    ApplicationRoleSettings
  ]

lookupReady :: PQ.Connection -> HinagataConfig -> FixturePlan -> Maybe (ConnectionTarget -> IO (Either Text ())) -> Deadline -> Text -> Text -> IO (Either BaselineError (Maybe BaselineRef))
lookupReady connection configuration plan hook deadline project digest = do
  let table = quoteSqlIdentifier (maintenanceSchema configuration) <> ".\"generations\""
      statement = Encoding.encodeUtf8 ("SELECT id, database_name::text, database_oid::text, ownership_token::text FROM " <> table <> " WHERE project_id = $1 AND fingerprint = $2 AND state = 'Ready' ORDER BY created_at DESC LIMIT 1")
  rows <- queryParamRows connection deadline Sql statement [Just (Encoding.encodeUtf8 project), Just (Encoding.encodeUtf8 digest)] 1
  pure $ case rows of
    Left failure -> Left (nativeFailure failure)
    Right [] -> Right Nothing
    Right [[Just generationId, Just name, Just oid, Just token]] -> do
      database <- maybe (Left (BaselineError "ready generation has an invalid database name" Nothing)) Right (either (const Nothing) Just (mkDatabaseName (Encoding.decodeUtf8 name)))
      number <- maybe (Left (BaselineError "ready generation has an invalid database OID" Nothing)) Right (readMaybe (Text.unpack (Encoding.decodeUtf8 oid)))
      let owned = OwnedDatabase database number (Encoding.decodeUtf8 token)
      Right (Just (BaselineRef database (Encoding.decodeUtf8 generationId) digest (CatalogIdentity 2 "") owned plan hook))
    Right _ -> Left (BaselineError "ready generation has incomplete identity" Nothing)

buildGeneration :: PQ.Connection -> ConnectionTarget -> SessionOptions -> CatalogIdentity -> HinagataConfig -> FixturePlan -> Text -> Text -> Text -> BaselineSpec -> Deadline -> IO (Either BaselineError (BaselineRef, PreparationKind))
buildGeneration connection maintenance options identity configuration plan project digest manifest spec deadline = do
  generated <- queryParamRows connection deadline Sql "SELECT gen_random_uuid()::text, gen_random_uuid()::text" [] 1
  case generated of
    Right [[Just identifier, Just tokenBytes]] -> do
      let generationId = Encoding.decodeUtf8 identifier
          token = Encoding.decodeUtf8 tokenBytes
          databaseText = "hg_" <> Text.take 8 digest <> "_" <> Text.take 20 (Text.filter (/= '-') token)
      case mkDatabaseName databaseText of
        Left _ -> pure (Left (BaselineError "generated database name is invalid" Nothing))
        Right database -> do
          let table = quoteSqlIdentifier (maintenanceSchema configuration) <> ".\"generations\""
              insertSql = Encoding.encodeUtf8 ("INSERT INTO " <> table <> " (id, project_id, fingerprint, fingerprint_manifest, database_name, ownership_token, state) VALUES ($1, $2, $3, jsonb_build_object('version', 1, 'manifest', $4::text), $5, $6::uuid, 'Building')")
              args = map (Just . Encoding.encodeUtf8) [generationId, project, digest, manifest, databaseText, token]
          inserted <- queryParamRows connection deadline Sql insertSql args 0
          case inserted of
            Left failure -> pure (Left (nativeFailure failure))
            Right _ -> do
              built <- construct connection maintenance options identity configuration plan generationId database token spec deadline
              case built of
                Left failure@BaselineError {cause = failureCause} -> do
                  let failedSql = Encoding.encodeUtf8 ("UPDATE " <> table <> " SET state = 'Failed', last_error = $2, updated_at = clock_timestamp() WHERE id = $1")
                  _ <- queryParamRows connection deadline Sql failedSql [Just identifier, Just (Encoding.encodeUtf8 (Text.take 512 failureCause))] 0
                  pure (Left failure)
                Right owned -> do
                  let readySql = Encoding.encodeUtf8 ("UPDATE " <> table <> " SET state = 'Ready', database_oid = $2::oid, updated_at = clock_timestamp() WHERE id = $1")
                  published <- queryParamRows connection deadline Sql readySql [Just identifier, Just (Encoding.encodeUtf8 (Text.pack (show (oid owned))))] 0
                  pure $ case published of
                    Left failure -> Left (nativeFailure failure)
                    Right _ -> Right (BaselineRef database generationId digest identity owned plan (clonePreparationHook spec), Built)
    Left failure -> pure (Left (nativeFailure failure))
    Right _ -> pure (Left (BaselineError "UUID generation returned an invalid result" Nothing))

construct :: PQ.Connection -> ConnectionTarget -> SessionOptions -> CatalogIdentity -> HinagataConfig -> FixturePlan -> Text -> DatabaseName -> Text -> BaselineSpec -> Deadline -> IO (Either BaselineError OwnedDatabase)
construct connection maintenance options identity configuration plan generationId database token BaselineSpec {migrationHook, verificationHook, requiredExtensions, requiredLocale} deadline = do
  let quoted = Access.quoteDatabase database
  created <- query connection deadline Sql (Encoding.encodeUtf8 ("CREATE DATABASE " <> quoted <> " TEMPLATE template0"))
  case created of
    Left NativeError {sqlState = Just "42501"} -> pure (Left (BaselineError "administration role lacks CREATEDB or template access" (Just "42501")))
    Left failure -> pure (Left (nativeFailure failure))
    Right () -> do
      let marker = "hinagata:v1:" <> clusterUuid identity <> ":" <> token
      commented <- query connection deadline Sql (Encoding.encodeUtf8 ("COMMENT ON DATABASE " <> quoted <> " IS " <> Access.quoteLiteral marker))
      case commented of
        Left failure -> pure (Left (nativeFailure failure))
        Right () -> do
          observed <- queryParamRows connection deadline Sql "SELECT oid::text FROM pg_database WHERE datname = $1" [Just (Encoding.encodeUtf8 (databaseNameText database))] 1
          case observed of
            Right [[Just oidBytes]] -> case readMaybe (Text.unpack (Encoding.decodeUtf8 oidBytes)) of
              Nothing -> pure (Left (BaselineError "created database has an invalid OID" Nothing))
              Just number -> do
                let owned = OwnedDatabase database number token
                    table = quoteSqlIdentifier (maintenanceSchema configuration) <> ".\"generations\""
                    bindSql = Encoding.encodeUtf8 ("UPDATE " <> table <> " SET database_oid = $2::oid, updated_at = clock_timestamp() WHERE id = $1 AND state = 'Building' RETURNING id")
                bound <- queryParamRows connection deadline Sql bindSql [Just (Encoding.encodeUtf8 generationId), Just oidBytes] 1
                case bound of
                  Left failure -> pure (Left (nativeFailure failure))
                  Right [[Just _]] -> do
                    prepared <- first accessFailure <$> Access.prepareAccess connection options configuration database deadline
                    case prepared of
                      Left failure -> pure (Left failure)
                      Right () -> do
                        case first accessFailure (Access.accessToTarget configuration (setup configuration) database) of
                          Left failure -> pure (Left failure)
                          Right setupTarget -> do
                            migrated <- timeout (positiveValue (setupDeadlineMs configuration) * 1000) (migrationHook setupTarget)
                            case migrated of
                              Nothing -> pure (Left (BaselineError "migration hook timed out" Nothing))
                              Just (Left _) -> pure (Left (BaselineError "migration hook failed" Nothing))
                              Just (Right ()) -> do
                                loaded <- loadInto setupTarget options plan
                                case loaded of
                                  Left _ -> pure (Left (BaselineError "base fixture load failed" Nothing))
                                  Right _ -> do
                                    verified <- timeout (positiveValue (setupDeadlineMs configuration) * 1000) (verificationHook setupTarget)
                                    case verified of
                                      Nothing -> pure (Left (BaselineError "verification hook timed out" Nothing))
                                      Just (Left _) -> pure (Left (BaselineError "verification hook failed" Nothing))
                                      Just (Right ()) -> do
                                        requirements <- checkRequirements connection options setupTarget database requiredExtensions requiredLocale deadline
                                        case requirements of
                                          Left failure -> pure (Left failure)
                                          Right () -> do
                                            sessions <- queryParamRows connection deadline Sql "SELECT count(*)::text FROM pg_stat_activity WHERE datname = $1" [Just (Encoding.encodeUtf8 (databaseNameText database))] 1
                                            case sessions of
                                              Right [[Just "0"]] -> do
                                                sealed <- query connection deadline Sql (Encoding.encodeUtf8 ("ALTER DATABASE " <> quoted <> " WITH ALLOW_CONNECTIONS false"))
                                                case sealed of
                                                  Left failure -> pure (Left (nativeFailure failure))
                                                  Right () -> do
                                                    remaining <- queryParamRows connection deadline Sql "SELECT count(*)::text FROM pg_stat_activity WHERE datname = $1" [Just (Encoding.encodeUtf8 (databaseNameText database))] 1
                                                    case remaining of
                                                      Right [[Just "0"]] -> do
                                                        evidence <- verifyOwnedDatabase maintenance options identity owned
                                                        pure $ case evidence of
                                                          Right OwnershipMatches -> Right owned
                                                          Right _ -> Left (BaselineError "sealed generation lost positive ownership" Nothing)
                                                          Left CatalogError {cause, sqlState} -> Left (BaselineError cause sqlState)
                                                      Right _ -> pure (Left (BaselineError "sealed baseline gained an open session" Nothing))
                                                      Left failure -> pure (Left (nativeFailure failure))
                                              Right _ -> pure (Left (BaselineError "baseline still has open sessions" Nothing))
                                              Left failure -> pure (Left (nativeFailure failure))
                  Right _ -> pure (Left (BaselineError "generation identity could not be bound" Nothing))
            Right _ -> pure (Left (BaselineError "created database is missing from the catalog" Nothing))
            Left failure -> pure (Left (nativeFailure failure))

checkRequirements :: PQ.Connection -> SessionOptions -> ConnectionTarget -> DatabaseName -> [Text] -> Maybe Text -> Deadline -> IO (Either BaselineError ())
checkRequirements maintenance options setupTarget database extensions locale deadline = do
  localeResult <- case locale of
    Nothing -> pure (Right ())
    Just expected -> do
      observed <- queryParamRows maintenance deadline Sql "SELECT datcollate FROM pg_database WHERE datname = $1" [Just (Encoding.encodeUtf8 (databaseNameText database))] 1
      pure $ case observed of
        Right [[Just actual]] | actual == Encoding.encodeUtf8 expected -> Right ()
        Right _ -> Left (BaselineError "baseline locale differs from the declared requirement" Nothing)
        Left failure -> Left (nativeFailure failure)
  case localeResult of
    Left failure -> pure (Left failure)
    Right () ->
      if null extensions
        then pure (Right ())
        else do
          opened <- withSession setupTarget options $ \session ->
            runExclusive session $ \connection sessionOptions -> do
              innerDeadline <- deadlineAfter (operationDeadlineMs sessionOptions)
              results <- traverse (checkExtension connection innerDeadline) extensions
              pure (Keep (() <$ sequence results))
          pure $ case opened of
            Left failure -> Left (sessionFailure failure)
            Right (Left failure) -> Left (sessionFailure failure)
            Right (Right result) -> result

checkExtension :: PQ.Connection -> Deadline -> Text -> IO (Either BaselineError ())
checkExtension connection deadline extension = do
  observed <- queryParamRows connection deadline Sql "SELECT extname::text FROM pg_extension WHERE extname = $1" [Just (Encoding.encodeUtf8 extension)] 1
  pure $ case observed of
    Right [[Just _]] -> Right ()
    Right _ -> Left (BaselineError "baseline lacks a declared extension" Nothing)
    Left failure -> Left (nativeFailure failure)

fingerprintManifest :: Int -> BaselineSpec -> Text
fingerprintManifest server BaselineSpec {configuration, basePlan, migrationRevision, verificationRevision, requiredExtensions, requiredLocale} =
  Text.intercalate
    "\n"
    [ "hinagata-fingerprint-v1",
      render (server `div` 10000),
      render (projectIdText (project configuration)),
      render (planDigest basePlan),
      render migrationRevision,
      render verificationRevision,
      render requiredExtensions,
      render requiredLocale,
      render (user (administration configuration)),
      render (user (setup configuration)),
      render (user (application configuration)),
      render (setupGrants configuration),
      render (applicationGrants configuration),
      render (setupSchemaGrants configuration),
      render (applicationSchemaGrants configuration),
      render (nonSecretSettings (setupSettings configuration)),
      render (nonSecretSettings (applicationSettings configuration))
    ]
  where
    render :: (Show a) => a -> Text
    render = Text.pack . show

    nonSecretSettings :: [RoleSetting] -> [(Text, Text)]
    nonSecretSettings = map (\RoleSetting {name, value} -> (sqlIdentifierText name, hex (SHA256.hash (Encoding.encodeUtf8 value))))

hex :: ByteString.ByteString -> Text
hex = Text.pack . concatMap digits . ByteString.unpack
  where
    digits byte = case showHex byte "" of [digit] -> ['0', digit]; value -> value

nativeFailure :: NativeError -> BaselineError
nativeFailure NativeError {reason, sqlState} = BaselineError reason sqlState

accessFailure :: Access.AccessError -> BaselineError
accessFailure Access.AccessError {cause, sqlState} = BaselineError cause sqlState

sessionFailure :: SessionError -> BaselineError
sessionFailure failure = BaselineError (Text.pack (show failure)) Nothing
