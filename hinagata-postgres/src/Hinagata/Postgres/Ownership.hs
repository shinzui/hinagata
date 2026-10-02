-- | Versioned maintenance-catalog bootstrap on a caller-selected database.
module Hinagata.Postgres.Ownership
  ( CatalogIdentity (..),
    CatalogError (..),
    OwnedDatabase (..),
    OwnershipEvidence (..),
    ensureCatalog,
    inspectCatalog,
    verifyOwnedDatabase,
  )
where

import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import Hinagata.Connection (ConnectionTarget)
import Hinagata.Postgres.Error (NativeError (..), NativePhase (..), SessionError (..))
import Hinagata.Postgres.Internal.Libpq
import Hinagata.Prelude
import Hinagata.Types (DatabaseName, SqlIdentifier, databaseNameText, quoteSqlIdentifier, sqlIdentifierText)
import Paths_hinagata_postgres (getDataFileName)

-- | The catalog format and cluster marker read back from the maintenance
-- database. The marker prevents records from one cluster being used in another.
data CatalogIdentity = CatalogIdentity
  { formatVersion :: !Int,
    clusterUuid :: !Text
  }
  deriving stock (Eq, Show)

-- | Expected bootstrap failures. Raw server messages are not retained.
data CatalogError = CatalogError
  { cause :: !Text,
    sqlState :: !(Maybe Text),
    cleanupFailure :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | Identity recorded when Hinagata allocated a database. A name alone is
-- never sufficient authority for cleanup.
data OwnedDatabase = OwnedDatabase
  { name :: !DatabaseName,
    oid :: !Int,
    token :: !Text
  }
  deriving stock (Eq, Show)

-- | Comparison against the current cluster catalog and database comment.
data OwnershipEvidence = OwnershipMatches | OwnershipMissing | OwnershipMismatch
  deriving stock (Eq, Show)

-- | Initialize a dedicated, absent version-2 schema or transactionally upgrade
-- an owned version-1 catalog. An occupied schema without Hinagata's version
-- marker is refused. The administration role must own an existing schema.
ensureCatalog :: ConnectionTarget -> SqlIdentifier -> SessionOptions -> IO (Either CatalogError CatalogIdentity)
ensureCatalog target schema options = do
  opened <- withSession target options $ \session ->
    runExclusive session $ \connection sessionOptions -> bootstrap connection schema sessionOptions
  pure $ case opened of
    Left failure -> Left (sessionFailure failure)
    Right (Left failure) -> Left (sessionFailure failure)
    Right (Right result) -> result

-- | Validate an existing catalog without creating a schema or changing any
-- catalog row. Cleanup previews use this entry point to remain read-only.
inspectCatalog :: ConnectionTarget -> SqlIdentifier -> SessionOptions -> IO (Either CatalogError CatalogIdentity)
inspectCatalog target schema options = do
  opened <- withSession target options $ \session ->
    runExclusive session $ \connection sessionOptions -> do
      deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
      let name = Encoding.encodeUtf8 (sqlIdentifierText schema)
      namespace <- queryParamRows connection deadline Sql "SELECT pg_get_userbyid(nspowner), current_user FROM pg_namespace WHERE nspname = $1" [Just name] 1
      checked <- case namespace of
        Left failure -> pure (Left (nativeFailure failure))
        Right [[Just owner, Just current]]
          | owner == current -> do
              inspected <- validateCatalog connection schema deadline
              pure $ case inspected of
                Right CatalogIdentity {formatVersion = 1} -> Left (CatalogError "maintenance catalog requires a version-2 upgrade through ensureCatalog" Nothing Nothing)
                other -> other
          | otherwise -> pure (Left (CatalogError "maintenance schema is owned by another role" Nothing Nothing))
        Right [] -> pure (Left (CatalogError "maintenance catalog does not exist" Nothing Nothing))
        Right _ -> pure (Left (CatalogError "maintenance schema identity is ambiguous" Nothing Nothing))
      pure (Keep checked)
  pure $ case opened of
    Left failure -> Left (sessionFailure failure)
    Right (Left failure) -> Left (sessionFailure failure)
    Right (Right result) -> result

-- | Recheck a recorded name, OID, and marker before any destructive action.
-- A missing or replaced database is reported without changing it.
verifyOwnedDatabase :: ConnectionTarget -> SessionOptions -> CatalogIdentity -> OwnedDatabase -> IO (Either CatalogError OwnershipEvidence)
verifyOwnedDatabase target options identity expected = do
  opened <- withSession target options $ \session ->
    runExclusive session $ \connection sessionOptions -> do
      deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
      checked <- checkOwnership connection deadline identity expected
      pure (either (Retire . Left) (Keep . Right) checked)
  pure $ case opened of
    Left failure -> Left (sessionFailure failure)
    Right (Left failure) -> Left (sessionFailure failure)
    Right (Right result) -> result

checkOwnership :: PQ.Connection -> Deadline -> CatalogIdentity -> OwnedDatabase -> IO (Either CatalogError OwnershipEvidence)
checkOwnership connection deadline identity expected = do
  let statement = "SELECT d.oid::text, s.description, pg_get_userbyid(d.datdba), current_user FROM pg_database d LEFT JOIN pg_shdescription s ON s.objoid = d.oid AND s.classoid = 'pg_database'::regclass WHERE d.datname = $1"
      expectedMarker = "hinagata:v1:" <> clusterUuid identity <> ":" <> token expected
  rows <- queryParamRows connection deadline Sql statement [Just (Encoding.encodeUtf8 (databaseNameText (name expected)))] 1
  pure $ case rows of
    Left failure -> Left (nativeFailure failure)
    Right [] -> Right OwnershipMissing
    Right [[Just actualOid, Just marker, Just owner, Just current]]
      | actualOid == Encoding.encodeUtf8 (Text.pack (show (oid expected))) && marker == Encoding.encodeUtf8 expectedMarker && owner == current -> Right OwnershipMatches
    Right _ -> Right OwnershipMismatch

bootstrap :: PQ.Connection -> SqlIdentifier -> SessionOptions -> IO (SessionDisposition (Either CatalogError CatalogIdentity))
bootstrap connection schema options = do
  deadline <- deadlineAfter (operationDeadlineMs options)
  begun <- query connection deadline Begin "BEGIN"
  case begun of
    Left failure -> pure (Retire (Left (nativeFailure failure)))
    Right () -> do
      result <- initialize connection schema deadline
      case result of
        Left failure -> rollbackCatalog connection options failure
        Right identity -> do
          committed <- query connection deadline Commit "COMMIT"
          case committed of
            Left failure -> pure (Retire (Left (nativeFailure failure)))
            Right () -> do
              status <- PQ.transactionStatus connection
              if status == PQ.TransIdle
                then pure (Keep (Right identity))
                else pure (Retire (Left (CatalogError "catalog transaction did not return to idle" Nothing Nothing)))

initialize :: PQ.Connection -> SqlIdentifier -> Deadline -> IO (Either CatalogError CatalogIdentity)
initialize connection schema deadline = do
  let name = Encoding.encodeUtf8 (sqlIdentifierText schema)
  locked <- queryParamRows connection deadline Sql "SELECT pg_advisory_xact_lock(1212761905, hashtext($1))" [Just name] 1
  case locked of
    Left failure -> pure (Left (nativeFailure failure))
    Right _ -> do
      namespace <- queryParamRows connection deadline Sql "SELECT pg_get_userbyid(nspowner), current_user FROM pg_namespace WHERE nspname = $1" [Just name] 1
      case namespace of
        Left failure -> pure (Left (nativeFailure failure))
        Right [] -> createCatalog connection schema deadline
        Right [[Just owner, Just current]]
          | owner == current -> do
              existing <- validateCatalog connection schema deadline
              case existing of
                Right CatalogIdentity {formatVersion = 1} -> upgradeCatalog connection schema deadline
                other -> pure other
          | otherwise -> pure (Left (CatalogError "maintenance schema is owned by another role" Nothing Nothing))
        Right _ -> pure (Left (CatalogError "maintenance schema identity is ambiguous" Nothing Nothing))

createCatalog :: PQ.Connection -> SqlIdentifier -> Deadline -> IO (Either CatalogError CatalogIdentity)
createCatalog connection schema deadline = do
  file <- getDataFileName "sql/catalog-v2.sql"
  source <- try @IOException (ByteString.readFile file)
  case source of
    Left _ -> pure (Left (CatalogError "catalog DDL is unavailable" Nothing Nothing))
    Right bytes -> do
      let statement =
            Encoding.encodeUtf8 $
              Text.replace "%SCHEMA%" (quoteSqlIdentifier schema) (Encoding.decodeUtf8 bytes)
      created <- query connection deadline Sql statement
      case created of
        Left failure -> pure (Left (nativeFailure failure))
        Right () -> validateCatalog connection schema deadline

upgradeCatalog :: PQ.Connection -> SqlIdentifier -> Deadline -> IO (Either CatalogError CatalogIdentity)
upgradeCatalog connection schema deadline = do
  file <- getDataFileName "sql/upgrade-v1-v2.sql"
  source <- try @IOException (ByteString.readFile file)
  case source of
    Left _ -> pure (Left (CatalogError "catalog upgrade DDL is unavailable" Nothing Nothing))
    Right bytes -> do
      let statement = Encoding.encodeUtf8 (Text.replace "%SCHEMA%" (quoteSqlIdentifier schema) (Encoding.decodeUtf8 bytes))
      upgraded <- query connection deadline Sql statement
      case upgraded of
        Left failure -> pure (Left (nativeFailure failure))
        Right () -> validateCatalog connection schema deadline

validateCatalog :: PQ.Connection -> SqlIdentifier -> Deadline -> IO (Either CatalogError CatalogIdentity)
validateCatalog connection schema deadline = do
  let name = Encoding.encodeUtf8 (sqlIdentifierText schema)
      structureQuery = "SELECT count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relname IN ('meta', 'generations', 'allocations', 'leases') AND c.relkind = 'r' AND c.relowner = current_user::regrole"
  structure <- queryParamRows connection deadline Sql structureQuery [Just name] 1
  case structure of
    Left failure -> pure (Left (nativeFailure failure))
    Right [[Just "4"]] -> do
      let statement = Encoding.encodeUtf8 ("SELECT format_version::text, cluster_uuid::text FROM " <> quoteSqlIdentifier schema <> ".\"meta\" WHERE singleton")
      rows <- queryParamRows connection deadline Sql statement [] 2
      case rows of
        Left failure -> pure (Left (nativeFailure failure))
        Right [[Just "1", Just uuid]] -> pure (Right (CatalogIdentity 1 (Encoding.decodeUtf8 uuid)))
        Right [[Just "2", Just uuid]] -> do
          let columnsQuery = "SELECT count(*)::text FROM information_schema.columns WHERE table_schema = $1 AND table_name IN ('generations', 'allocations') AND column_name = 'last_error' AND data_type = 'text'"
          columns <- queryParamRows connection deadline Sql columnsQuery [Just name] 1
          pure $ case columns of
            Left failure -> Left (nativeFailure failure)
            Right [[Just "2"]] -> Right (CatalogIdentity 2 (Encoding.decodeUtf8 uuid))
            Right _ -> Left (CatalogError "maintenance catalog lacks version-2 columns" Nothing Nothing)
        Right _ -> pure (Left (CatalogError "maintenance catalog has an unsupported or invalid format" Nothing Nothing))
    Right _ -> pure (Left (CatalogError "maintenance schema lacks a complete Hinagata catalog" Nothing Nothing))

rollbackCatalog :: PQ.Connection -> SessionOptions -> CatalogError -> IO (SessionDisposition (Either CatalogError CatalogIdentity))
rollbackCatalog connection options failure = do
  deadline <- deadlineAfter (cleanupDeadlineMs options)
  rolled <- query connection deadline Rollback "ROLLBACK"
  case rolled of
    Left cleanup -> pure (Retire (Left failure {cleanupFailure = Just (reason cleanup)}))
    Right () -> do
      status <- PQ.transactionStatus connection
      if status == PQ.TransIdle
        then pure (Keep (Left failure))
        else pure (Retire (Left failure {cleanupFailure = Just "catalog rollback did not return to idle"}))

nativeFailure :: NativeError -> CatalogError
nativeFailure NativeError {reason, sqlState} = CatalogError reason sqlState Nothing

sessionFailure :: SessionError -> CatalogError
sessionFailure failure = CatalogError (Text.pack (show failure)) Nothing Nothing
