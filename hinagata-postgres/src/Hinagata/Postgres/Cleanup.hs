-- | Preview and explicitly apply ownership-checked clone recovery.
module Hinagata.Postgres.Cleanup
  ( CleanupDisposition (..),
    CleanupCandidate (..),
    CleanupSelection (..),
    CleanupResult (..),
    CleanupError (..),
    planCleanup,
    inspectLease,
    applyCleanup,
    releaseLease,
    preserveLease,
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import Hinagata.Config
import Hinagata.Connection (ConnectionTarget)
import Hinagata.Postgres.Error (NativeError (..), NativePhase (..), SessionError)
import Hinagata.Postgres.Internal.Access qualified as Access
import Hinagata.Postgres.Internal.Libpq
import Hinagata.Postgres.Ownership qualified as Own
import Hinagata.Prelude
import Hinagata.Types
import Text.Read (readMaybe)

-- | Read-only classification. An ambiguous identity is never deletion
-- authority, even when a database happens to have the recorded name.
data CleanupDisposition = Live | Orphaned | Retained | Ambiguous | Missing | Foreign
  deriving stock (Eq, Show)

-- | Catalog identity and evidence at preview time. Apply always rechecks.
data CleanupCandidate = CleanupCandidate
  { allocationId :: !Text,
    leaseId :: !(Maybe Text),
    database :: !DatabaseName,
    state :: !Text,
    disposition :: !CleanupDisposition
  }
  deriving stock (Eq, Show)

-- | Ordinary recovery touches only orphaned active work. Retained resources
-- require an explicit selected ID and the broader policy.
data CleanupSelection = OrphansOnly | IncludeRetained
  deriving stock (Eq, Show)

-- | Per-ID apply outcome. A refusal leaves the database and catalog visible.
data CleanupResult = Released !Text | AlreadyReleased !Text | Preserved !Text | Skipped !Text !CleanupDisposition | Refused !Text !Text
  deriving stock (Eq, Show)

-- | Non-secret preview or apply failure.
data CleanupError = CleanupError
  { cause :: !Text,
    sqlState :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data Snapshot = Snapshot
  { allocation :: !Text,
    generation :: !Text,
    databaseName :: !DatabaseName,
    databaseOid :: !(Maybe Int),
    ownershipToken :: !Text,
    allocationState :: !Text,
    recordedLease :: !(Maybe Text)
  }

-- | Inspect project allocations in stable batches. A transient try-lock may
-- be taken and released to classify liveness; no catalog row or database is
-- changed. Results are advisory and grant no later deletion authority.
planCleanup :: HinagataConfig -> IO (Either CleanupError [CleanupCandidate])
planCleanup configuration = withCatalog configuration $ \maintenance options identity -> do
  opened <- withSession maintenance options $ \session ->
    runExclusive session $ \connection sessionOptions -> do
      deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
      candidates <- collect connection maintenance options identity configuration deadline "" []
      pure (Keep candidates)
  pure (flatten opened)

-- | Inspect one lease, including an already released record, without changing
-- catalog or database state. A held callback lock is reported as Live.
inspectLease :: HinagataConfig -> Text -> IO (Either CleanupError (Maybe CleanupCandidate))
inspectLease configuration identifier = withCatalog configuration $ \maintenance options identity -> do
  opened <- withSession maintenance options $ \session ->
    runExclusive session $ \connection sessionOptions -> do
      deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
      snapshot <- lookupLeaseSnapshot connection configuration deadline identifier
      result <- case snapshot of
        Left problem -> pure (Left problem)
        Right Nothing -> pure (Right Nothing)
        Right (Just found) -> fmap Just <$> classify connection maintenance options identity deadline found
      pure (Keep result)
  pure (flatten opened)

-- | Revalidate each explicitly selected allocation under its generation and
-- lease locks. A live lock, protected target, or mismatched identity refuses
-- deletion. Missing matching clones are idempotently marked Released.
applyCleanup :: HinagataConfig -> CleanupSelection -> [Text] -> IO (Either CleanupError [CleanupResult])
applyCleanup configuration selection identifiers = withCatalog configuration $ \maintenance options identity ->
  sequence <$> traverse (applyOne configuration selection maintenance options identity) identifiers

-- | Explicitly release one retained lease by its public lease ID. The ID is
-- resolved in the project catalog, then apply repeats every ownership check.
releaseLease :: HinagataConfig -> Text -> IO (Either CleanupError CleanupResult)
releaseLease configuration identifier = do
  resolved <- resolveLease configuration identifier
  case resolved of
    Left problem -> pure (Left problem)
    Right Nothing -> pure (Right (Refused identifier "lease ID was not found in this project"))
    Right (Just allocationId) -> do
      released <- applyCleanup configuration IncludeRetained [allocationId]
      pure $ case released of
        Left problem -> Left problem
        Right [result] -> Right result
        Right _ -> Left (failure "lease release returned an invalid result")

-- | Explicitly preserve an ended or orphaned lease. Live callbacks, unbound
-- identities, missing databases, and foreign ownership evidence are refused.
preserveLease :: HinagataConfig -> Text -> IO (Either CleanupError CleanupResult)
preserveLease configuration identifier = do
  resolved <- resolveLease configuration identifier
  case resolved of
    Left problem -> pure (Left problem)
    Right Nothing -> pure (Right (Refused identifier "lease ID was not found in this project"))
    Right (Just allocationId) -> withCatalog configuration $ \maintenance options identity -> preserveOne configuration maintenance options identity allocationId

resolveLease :: HinagataConfig -> Text -> IO (Either CleanupError (Maybe Text))
resolveLease configuration identifier = withCatalog configuration $ \maintenance options _ -> do
  opened <- withSession maintenance options $ \session ->
    runExclusive session $ \connection sessionOptions -> do
      deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
      let schema = quoteSqlIdentifier (maintenanceSchema configuration)
          statement = Encoding.encodeUtf8 ("SELECT a.id FROM " <> schema <> ".\"leases\" l JOIN " <> schema <> ".\"allocations\" a ON a.id = l.allocation_id WHERE l.id = $1 AND a.project_id = $2")
          args = map (Just . Encoding.encodeUtf8) [identifier, projectIdText (project configuration)]
      rows <- queryParamRows connection deadline Sql statement args 1
      pure
        ( Keep
            ( case rows of
                Left problem -> Left (nativeFailure problem)
                Right [[Just allocationId]] -> Right (Just (Encoding.decodeUtf8 allocationId))
                Right [] -> Right Nothing
                Right _ -> Left (failure "lease identity is ambiguous")
            )
        )
  pure (flatten opened)

withCatalog :: HinagataConfig -> (ConnectionTarget -> SessionOptions -> Own.CatalogIdentity -> IO (Either CleanupError a)) -> IO (Either CleanupError a)
withCatalog configuration action =
  case first accessFailure (Access.adminTarget configuration (maintenanceDatabase configuration)) of
    Left problem -> pure (Left problem)
    Right maintenance -> do
      let options = defaultSessionOptions {operationDeadlineMs = positiveValue (acquisitionDeadlineMs configuration)}
      catalog <- Own.inspectCatalog maintenance (maintenanceSchema configuration) options
      case catalog of
        Left problem -> pure (Left (catalogFailure problem))
        Right identity -> action maintenance options identity

collect :: PQ.Connection -> ConnectionTarget -> SessionOptions -> Own.CatalogIdentity -> HinagataConfig -> Deadline -> Text -> [CleanupCandidate] -> IO (Either CleanupError [CleanupCandidate])
collect connection maintenance options identity configuration deadline cursor accumulated = do
  let table = quoteSqlIdentifier (maintenanceSchema configuration)
      statement = Encoding.encodeUtf8 ("SELECT a.id, a.generation_id, a.database_name::text, a.database_oid::text, a.ownership_token::text, a.state, l.id FROM " <> table <> ".\"allocations\" a LEFT JOIN " <> table <> ".\"leases\" l ON l.allocation_id = a.id WHERE a.project_id = $1 AND a.state <> 'Released' AND a.id > $2 ORDER BY a.id LIMIT 100")
      args = map (Just . Encoding.encodeUtf8) [projectIdText (project configuration), cursor]
  page <- queryParamRows connection deadline Sql statement args 100
  case page of
    Left problem -> pure (Left (nativeFailure problem))
    Right rows -> case traverse decodeSnapshot rows of
      Left problem -> pure (Left problem)
      Right snapshots -> do
        classified <- traverse (classify connection maintenance options identity deadline) snapshots
        case sequence classified of
          Left problem -> pure (Left problem)
          Right candidates ->
            if length rows < 100
              then pure (Right (reverse accumulated ++ candidates))
              else collect connection maintenance options identity configuration deadline (allocation (last snapshots)) (reverse candidates ++ accumulated)

classify :: PQ.Connection -> ConnectionTarget -> SessionOptions -> Own.CatalogIdentity -> Deadline -> Snapshot -> IO (Either CleanupError CleanupCandidate)
classify connection maintenance options identity deadline snapshot = do
  disposition <- case databaseOid snapshot of
    Nothing -> pure (Right Ambiguous)
    Just number -> do
      held <- case recordedLease snapshot of
        Nothing -> pure (Right False)
        Just identifier -> isLeaseHeld connection deadline identifier
      case held of
        Left problem -> pure (Left problem)
        Right True -> pure (Right Live)
        Right False -> do
          evidence <- Own.verifyOwnedDatabase maintenance options identity (Own.OwnedDatabase (databaseName snapshot) number (ownershipToken snapshot))
          pure $ case evidence of
            Left problem -> Left (catalogFailure problem)
            Right Own.OwnershipMatches
              | allocationState snapshot `elem` ["Detached", "Preserved"] -> Right Retained
              | otherwise -> Right Orphaned
            Right Own.OwnershipMissing -> Right Missing
            Right Own.OwnershipMismatch -> Right Foreign
  pure $ CleanupCandidate (allocation snapshot) (recordedLease snapshot) (databaseName snapshot) (allocationState snapshot) <$> disposition

isLeaseHeld :: PQ.Connection -> Deadline -> Text -> IO (Either CleanupError Bool)
isLeaseHeld connection deadline identifier = do
  let key = Encoding.encodeUtf8 (leaseLockKey identifier)
  attempted <- queryParamRows connection deadline Sql "SELECT pg_try_advisory_lock(1212761905, hashtext($1))::text" [Just key] 1
  case attempted of
    Left problem -> pure (Left (nativeFailure problem))
    Right [[Just "false"]] -> pure (Right True)
    Right [[Just "true"]] -> do
      unlocked <- queryParamRows connection deadline Sql "SELECT pg_advisory_unlock(1212761905, hashtext($1))::text" [Just key] 1
      pure $ case unlocked of
        Right [[Just "true"]] -> Right False
        Left problem -> Left (nativeFailure problem)
        Right _ -> Left (failure "lease preview lock could not be released")
    Right _ -> pure (Left (failure "lease preview lock returned an invalid result"))

applyOne :: HinagataConfig -> CleanupSelection -> ConnectionTarget -> SessionOptions -> Own.CatalogIdentity -> Text -> IO (Either CleanupError CleanupResult)
applyOne configuration selection maintenance options identity identifier = do
  opened <- withSession maintenance options $ \session ->
    runExclusive session $ \connection sessionOptions -> do
      deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
      initial <- lookupSnapshot connection configuration deadline identifier
      result <- case initial of
        Left problem -> pure (Left problem)
        Right Nothing -> pure (Right (AlreadyReleased identifier))
        Right (Just firstSnapshot) -> do
          locked <- queryParamRows connection deadline Sql "SELECT pg_advisory_lock(1212761905, hashtext($1))" [Just (Encoding.encodeUtf8 (generationLockKey (generation firstSnapshot)))] 1
          case locked of
            Left problem -> pure (Left (nativeFailure problem))
            Right _ -> do
              refreshed <- lookupSnapshot connection configuration deadline identifier
              case refreshed of
                Left problem -> pure (Left problem)
                Right Nothing -> pure (Right (AlreadyReleased identifier))
                Right (Just snapshot)
                  | generation snapshot == generation firstSnapshot -> applyLocked connection maintenance options identity configuration selection deadline snapshot
                  | otherwise -> pure (Right (Refused identifier "allocation generation changed while acquiring its lock"))
      pure (Keep result)
  pure (flatten opened)

preserveOne :: HinagataConfig -> ConnectionTarget -> SessionOptions -> Own.CatalogIdentity -> Text -> IO (Either CleanupError CleanupResult)
preserveOne configuration maintenance options identity identifier = do
  opened <- withSession maintenance options $ \session ->
    runExclusive session $ \connection sessionOptions -> do
      deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
      initial <- lookupSnapshot connection configuration deadline identifier
      result <- case initial of
        Left problem -> pure (Left problem)
        Right Nothing -> pure (Right (Refused identifier "allocation was not found in this project"))
        Right (Just firstSnapshot) -> do
          locked <- queryParamRows connection deadline Sql "SELECT pg_advisory_lock(1212761905, hashtext($1))" [Just (Encoding.encodeUtf8 (generationLockKey (generation firstSnapshot)))] 1
          case locked of
            Left problem -> pure (Left (nativeFailure problem))
            Right _ -> do
              refreshed <- lookupSnapshot connection configuration deadline identifier
              case refreshed of
                Left problem -> pure (Left problem)
                Right Nothing -> pure (Right (Refused identifier "allocation disappeared while acquiring its lock"))
                Right (Just snapshot)
                  | generation snapshot == generation firstSnapshot -> preserveLocked connection maintenance options identity configuration deadline snapshot
                  | otherwise -> pure (Right (Refused identifier "allocation generation changed while acquiring its lock"))
      pure (Keep result)
  pure (flatten opened)

preserveLocked :: PQ.Connection -> ConnectionTarget -> SessionOptions -> Own.CatalogIdentity -> HinagataConfig -> Deadline -> Snapshot -> IO (Either CleanupError CleanupResult)
preserveLocked connection maintenance options identity configuration deadline snapshot
  | allocationState snapshot == "Released" = pure (Right (AlreadyReleased (allocation snapshot)))
  | databaseName snapshot == maintenanceDatabase configuration || databaseNameText (databaseName snapshot) `elem` ["template0", "template1"] = pure (Right (Refused (allocation snapshot) "protected database target"))
  | otherwise = do
      template <- generationDatabase connection configuration deadline (generation snapshot)
      case template of
        Left problem -> pure (Left problem)
        Right Nothing -> pure (Right (Refused (allocation snapshot) "generation record is missing"))
        Right (Just baselineName) | baselineName == databaseName snapshot -> pure (Right (Refused (allocation snapshot) "allocation names its baseline template"))
        Right (Just _) -> do
          free <- case recordedLease snapshot of
            Nothing -> pure (Right False)
            Just lease -> tryHoldLease connection deadline lease
          case free of
            Left problem -> pure (Left problem)
            Right False -> pure (Right (Skipped (allocation snapshot) Live))
            Right True -> case databaseOid snapshot of
              Nothing -> pure (Right (Refused (allocation snapshot) "allocation has no bound database OID"))
              Just number -> do
                evidence <- Own.verifyOwnedDatabase maintenance options identity (Own.OwnedDatabase (databaseName snapshot) number (ownershipToken snapshot))
                case evidence of
                  Left problem -> pure (Left (catalogFailure problem))
                  Right Own.OwnershipMismatch -> pure (Right (Refused (allocation snapshot) "database ownership evidence differs"))
                  Right Own.OwnershipMissing -> pure (Right (Refused (allocation snapshot) "database is missing"))
                  Right Own.OwnershipMatches -> do
                    updated <- if allocationState snapshot == "Preserved" then pure (Right ()) else changeState connection configuration deadline snapshot "Preserved"
                    pure (Preserved (allocation snapshot) <$ updated)

applyLocked :: PQ.Connection -> ConnectionTarget -> SessionOptions -> Own.CatalogIdentity -> HinagataConfig -> CleanupSelection -> Deadline -> Snapshot -> IO (Either CleanupError CleanupResult)
applyLocked connection maintenance options identity configuration selection deadline snapshot
  | allocationState snapshot == "Released" = pure (Right (AlreadyReleased (allocation snapshot)))
  | databaseName snapshot == maintenanceDatabase configuration || databaseNameText (databaseName snapshot) `elem` ["template0", "template1"] = pure (Right (Refused (allocation snapshot) "protected database target"))
  | allocationState snapshot `elem` ["Detached", "Preserved"] && selection == OrphansOnly = pure (Right (Skipped (allocation snapshot) Retained))
  | otherwise = do
      template <- generationDatabase connection configuration deadline (generation snapshot)
      case template of
        Left problem -> pure (Left problem)
        Right Nothing -> pure (Right (Refused (allocation snapshot) "generation record is missing"))
        Right (Just baselineName) | baselineName == databaseName snapshot -> pure (Right (Refused (allocation snapshot) "allocation names its baseline template"))
        Right (Just _) -> do
          free <- case recordedLease snapshot of
            Nothing -> pure (Right True)
            Just lease -> tryHoldLease connection deadline lease
          case free of
            Left problem -> pure (Left problem)
            Right False -> pure (Right (Skipped (allocation snapshot) Live))
            Right True -> case databaseOid snapshot of
              Nothing -> pure (Right (Refused (allocation snapshot) "allocation has no bound database OID"))
              Just number -> do
                evidence <- Own.verifyOwnedDatabase maintenance options identity (Own.OwnedDatabase (databaseName snapshot) number (ownershipToken snapshot))
                case evidence of
                  Left problem -> pure (Left (catalogFailure problem))
                  Right Own.OwnershipMismatch -> pure (Right (Refused (allocation snapshot) "database ownership evidence differs"))
                  Right Own.OwnershipMissing -> finishReleased connection configuration deadline snapshot
                  Right Own.OwnershipMatches -> do
                    releasing <- changeState connection configuration deadline snapshot "Releasing"
                    case releasing of
                      Left problem -> pure (Left problem)
                      Right () -> do
                        dropped <- query connection deadline Sql (Encoding.encodeUtf8 ("DROP DATABASE " <> Access.quoteDatabase (databaseName snapshot) <> " WITH (FORCE)"))
                        case dropped of
                          Left problem -> do
                            _ <- changeState connection configuration deadline snapshot "CleanupFailed"
                            let statement = Encoding.encodeUtf8 ("UPDATE " <> quoteSqlIdentifier (maintenanceSchema configuration) <> ".\"allocations\" SET last_error = $2 WHERE id = $1")
                            _ <- queryParamRows connection deadline Sql statement [Just (Encoding.encodeUtf8 (allocation snapshot)), Just (Encoding.encodeUtf8 (Text.take 512 (reason problem)))] 0
                            pure (Left (nativeFailure problem))
                          Right () -> finishReleased connection configuration deadline snapshot

finishReleased :: PQ.Connection -> HinagataConfig -> Deadline -> Snapshot -> IO (Either CleanupError CleanupResult)
finishReleased connection configuration deadline snapshot = do
  updated <- changeState connection configuration deadline snapshot "Released"
  pure (Released (allocation snapshot) <$ updated)

tryHoldLease :: PQ.Connection -> Deadline -> Text -> IO (Either CleanupError Bool)
tryHoldLease connection deadline identifier = do
  attempted <- queryParamRows connection deadline Sql "SELECT pg_try_advisory_lock(1212761905, hashtext($1))::text" [Just (Encoding.encodeUtf8 (leaseLockKey identifier))] 1
  pure $ case attempted of
    Left problem -> Left (nativeFailure problem)
    Right [[Just "true"]] -> Right True
    Right [[Just "false"]] -> Right False
    Right _ -> Left (failure "lease lock returned an invalid result")

generationDatabase :: PQ.Connection -> HinagataConfig -> Deadline -> Text -> IO (Either CleanupError (Maybe DatabaseName))
generationDatabase connection configuration deadline identifier = do
  let table = quoteSqlIdentifier (maintenanceSchema configuration) <> ".\"generations\""
      statement = Encoding.encodeUtf8 ("SELECT database_name::text FROM " <> table <> " WHERE id = $1")
  rows <- queryParamRows connection deadline Sql statement [Just (Encoding.encodeUtf8 identifier)] 1
  pure $ case rows of
    Left problem -> Left (nativeFailure problem)
    Right [] -> Right Nothing
    Right [[Just database]] -> Just <$> first failure (mkDatabaseName (Encoding.decodeUtf8 database))
    Right _ -> Left (failure "generation database identity is invalid")

changeState :: PQ.Connection -> HinagataConfig -> Deadline -> Snapshot -> Text -> IO (Either CleanupError ())
changeState connection configuration deadline snapshot next = do
  let schema = quoteSqlIdentifier (maintenanceSchema configuration)
      statement = Encoding.encodeUtf8 ("WITH allocation_change AS (UPDATE " <> schema <> ".\"allocations\" SET state = $2, updated_at = clock_timestamp() WHERE id = $1 RETURNING id), lease_change AS (UPDATE " <> schema <> ".\"leases\" SET state = $2, updated_at = clock_timestamp() WHERE allocation_id IN (SELECT id FROM allocation_change) RETURNING id) SELECT allocation_change.id, (SELECT count(*)::text FROM lease_change) FROM allocation_change")
      args = map (Just . Encoding.encodeUtf8) [allocation snapshot, next]
  rows <- queryParamRows connection deadline Sql statement args 1
  pure $ case rows of
    Right [[Just _, Just _]] -> Right ()
    Left problem -> Left (nativeFailure problem)
    Right _ -> Left (failure "allocation state record disappeared")

lookupSnapshot :: PQ.Connection -> HinagataConfig -> Deadline -> Text -> IO (Either CleanupError (Maybe Snapshot))
lookupSnapshot connection configuration deadline identifier = do
  let schema = quoteSqlIdentifier (maintenanceSchema configuration)
      statement = Encoding.encodeUtf8 ("SELECT a.id, a.generation_id, a.database_name::text, a.database_oid::text, a.ownership_token::text, a.state, l.id FROM " <> schema <> ".\"allocations\" a LEFT JOIN " <> schema <> ".\"leases\" l ON l.allocation_id = a.id WHERE a.id = $1 AND a.project_id = $2")
      args = map (Just . Encoding.encodeUtf8) [identifier, projectIdText (project configuration)]
  rows <- queryParamRows connection deadline Sql statement args 1
  pure $ case rows of
    Left problem -> Left (nativeFailure problem)
    Right [] -> Right Nothing
    Right [row] -> Just <$> decodeSnapshot row
    Right _ -> Left (failure "allocation identity is ambiguous")

lookupLeaseSnapshot :: PQ.Connection -> HinagataConfig -> Deadline -> Text -> IO (Either CleanupError (Maybe Snapshot))
lookupLeaseSnapshot connection configuration deadline identifier = do
  let schema = quoteSqlIdentifier (maintenanceSchema configuration)
      statement = Encoding.encodeUtf8 ("SELECT a.id, a.generation_id, a.database_name::text, a.database_oid::text, a.ownership_token::text, a.state, l.id FROM " <> schema <> ".\"allocations\" a JOIN " <> schema <> ".\"leases\" l ON l.allocation_id = a.id WHERE l.id = $1 AND a.project_id = $2")
      args = map (Just . Encoding.encodeUtf8) [identifier, projectIdText (project configuration)]
  rows <- queryParamRows connection deadline Sql statement args 1
  pure $ case rows of
    Left problem -> Left (nativeFailure problem)
    Right [] -> Right Nothing
    Right [row] -> Just <$> decodeSnapshot row
    Right _ -> Left (failure "lease identity is ambiguous")

decodeSnapshot :: [Maybe ByteString] -> Either CleanupError Snapshot
decodeSnapshot [Just identifier, Just generation, Just database, maybeOid, Just token, Just state, maybeLease] = do
  name <- first failure (mkDatabaseName (Encoding.decodeUtf8 database))
  number <- case maybeOid of
    Nothing -> Right Nothing
    Just value -> maybe (Left (failure "allocation has an invalid database OID")) (Right . Just) (readMaybe (Text.unpack (Encoding.decodeUtf8 value)))
  pure Snapshot {allocation = Encoding.decodeUtf8 identifier, generation = Encoding.decodeUtf8 generation, databaseName = name, databaseOid = number, ownershipToken = Encoding.decodeUtf8 token, allocationState = Encoding.decodeUtf8 state, recordedLease = Encoding.decodeUtf8 <$> maybeLease}
decodeSnapshot _ = Left (failure "allocation has incomplete identity")

flatten :: Either SessionError (Either SessionError (Either CleanupError a)) -> Either CleanupError a
flatten = either (Left . sessionFailure) (either (Left . sessionFailure) id)

failure :: Text -> CleanupError
failure cause = CleanupError cause Nothing

nativeFailure :: NativeError -> CleanupError
nativeFailure NativeError {reason, sqlState} = CleanupError reason sqlState

catalogFailure :: Own.CatalogError -> CleanupError
catalogFailure Own.CatalogError {cause, sqlState} = CleanupError cause sqlState

accessFailure :: Access.AccessError -> CleanupError
accessFailure Access.AccessError {cause, sqlState} = CleanupError cause sqlState

sessionFailure :: SessionError -> CleanupError
sessionFailure problem = failure (Text.pack (show problem))

generationLockKey :: Text -> Text
generationLockKey identifier = "generation:" <> identifier

leaseLockKey :: Text -> Text
leaseLockKey identifier = "lease:" <> identifier
