-- | Shared database grants and role-specific settings for generations and clones.
module Hinagata.Postgres.Internal.Access
  ( AccessError (..),
    prepareAccess,
    adminTarget,
    accessToTarget,
    quoteDatabase,
    quoteLiteral,
  )
where

import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import Hinagata.Config
import Hinagata.Connection
import Hinagata.Postgres.Error (NativeError (..), NativePhase (..), SessionError (..))
import Hinagata.Postgres.Internal.Libpq
import Hinagata.Prelude
import Hinagata.Types

data AccessError = AccessError
  { cause :: !Text,
    sqlState :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

prepareAccess :: PQ.Connection -> SessionOptions -> HinagataConfig -> DatabaseName -> Deadline -> IO (Either AccessError ())
prepareAccess connection options configuration database deadline = do
  let grants = [(setup configuration, setupGrants configuration), (application configuration, applicationGrants configuration)]
  databaseGrants <- traverse (uncurry (grantDatabase connection deadline database)) grants
  case sequence databaseGrants of
    Left failure -> pure (Left failure)
    Right _ -> do
      admin <- pure (adminTarget configuration database)
      case admin of
        Left failure -> pure (Left failure)
        Right target -> do
          opened <- withSession target options $ \session ->
            runExclusive session $ \inner innerOptions -> do
              innerDeadline <- deadlineAfter (operationDeadlineMs innerOptions)
              outcomes <- traverse (grantSchema inner innerDeadline) ([(setup configuration, item) | item <- setupSchemaGrants configuration] ++ [(application configuration, item) | item <- applicationSchemaGrants configuration])
              pure (Keep (sequence outcomes))
          case opened of
            Left failure -> pure (Left (accessSessionFailure failure))
            Right (Left failure) -> pure (Left (accessSessionFailure failure))
            Right (Right (Left failure)) -> pure (Left failure)
            Right (Right (Right _)) -> do
              setupResult <- applyRoleSettings configuration options database (setup configuration) (setupSettings configuration)
              case setupResult of
                Left failure -> pure (Left failure)
                Right () -> applyRoleSettings configuration options database (application configuration) (applicationSettings configuration)

applyRoleSettings :: HinagataConfig -> SessionOptions -> DatabaseName -> AccessConfig -> [RoleSetting] -> IO (Either AccessError ())
applyRoleSettings _ _ _ _ [] = pure (Right ())
applyRoleSettings configuration options database access settings =
  case (accessToTarget configuration access database, quoteRole (user access)) of
    (Left failure, _) -> pure (Left failure)
    (_, Left failure) -> pure (Left failure)
    (Right target, Right role) -> do
      opened <- withSession target options $ \session ->
        runExclusive session $ \connection sessionOptions -> do
          deadline <- deadlineAfter (operationDeadlineMs sessionOptions)
          let apply [] = pure (Right ())
              apply (entry : rest) = do
                result <- setRoleSetting connection deadline role database entry
                either (pure . Left) (const (apply rest)) result
          begun <- query connection deadline Begin "BEGIN"
          case begun of
            Left failure -> pure (Retire (Left (accessNativeFailure failure)))
            Right () -> do
              result <- apply settings
              case result of
                Right () -> do
                  committed <- query connection deadline Commit "COMMIT"
                  pure $ either (Retire . Left . accessNativeFailure) (const (Keep (Right ()))) committed
                Left failure -> do
                  cleanup <- deadlineAfter (cleanupDeadlineMs sessionOptions)
                  rolled <- query connection cleanup Rollback "ROLLBACK"
                  pure $ case rolled of
                    Right () -> Keep (Left failure)
                    Left _ -> Retire (Left failure)
      pure $ case opened of
        Left failure -> Left (accessSessionFailure failure)
        Right (Left failure) -> Left (accessSessionFailure failure)
        Right (Right result) -> () <$ result

setRoleSetting :: PQ.Connection -> Deadline -> Text -> DatabaseName -> RoleSetting -> IO (Either AccessError ())
setRoleSetting connection deadline role database RoleSetting {name, value}
  | Text.any (== '\0') value = pure (Left (AccessError "role setting contains NUL" Nothing))
  | otherwise = do
      let prefix = "ALTER ROLE " <> role <> " IN DATABASE " <> quoteDatabase database <> " SET " <> quoteSqlIdentifier name
          persist suffix = either (Left . accessNativeFailure) Right <$> query connection deadline Sql (Encoding.encodeUtf8 (prefix <> suffix))
      if Text.toLower (sqlIdentifierText name) `elem` quotedListSettings
        then do
          interpreted <- queryParamRows connection deadline Sql "SELECT pg_catalog.set_config($1, $2, true)" (map (Just . Encoding.encodeUtf8) [sqlIdentifierText name, value]) 1
          case interpreted of
            Left failure -> pure (Left (accessNativeFailure failure))
            Right _ -> persist " FROM CURRENT"
        else persist (" TO " <> quoteSettingLiteral value)

-- Explicit escape-string syntax preserves backslashes independently of the
-- persistence role's standard_conforming_strings default.
quoteSettingLiteral :: Text -> Text
quoteSettingLiteral value = "E'" <> Text.replace "'" "''" (Text.replace "\\" "\\\\" value) <> "'"

-- PostgreSQL's GUC_LIST_QUOTE parameters (also enumerated by pg_dump).
-- A single SQL literal would quote the entire list as one item. Other settings
-- keep scalar assignment so read-only, role, encoding, and timeout declarations
-- cannot change the persistence session before ALTER ROLE executes.
quotedListSettings :: [Text]
quotedListSettings =
  [ "search_path",
    "temp_tablespaces",
    "session_preload_libraries",
    "local_preload_libraries",
    "shared_preload_libraries",
    "unix_socket_directories",
    "oauth_validator_libraries",
    "output_plugin_libraries"
  ]

grantDatabase :: PQ.Connection -> Deadline -> DatabaseName -> AccessConfig -> [DatabaseGrant] -> IO (Either AccessError ())
grantDatabase connection deadline database access grants =
  case quoteRole (user access) of
    Left failure -> pure (Left failure)
    Right role ->
      if null grants
        then pure (Right ())
        else do
          let privileges = Text.intercalate ", " (map grantName grants)
              statement = Encoding.encodeUtf8 ("GRANT " <> privileges <> " ON DATABASE " <> quoteDatabase database <> " TO " <> role)
          either (Left . accessNativeFailure) Right <$> query connection deadline Sql statement

grantSchema :: PQ.Connection -> Deadline -> (AccessConfig, SchemaGrant) -> IO (Either AccessError ())
grantSchema connection deadline (access, SchemaGrant {schema, privilege}) =
  case quoteRole (user access) of
    Left failure -> pure (Left failure)
    Right role -> do
      let name = case privilege of SchemaUsage -> "USAGE"; SchemaCreate -> "CREATE"
          statement = Encoding.encodeUtf8 ("GRANT " <> name <> " ON SCHEMA " <> quoteSqlIdentifier schema <> " TO " <> role)
      either (Left . accessNativeFailure) Right <$> query connection deadline Sql statement

grantName :: DatabaseGrant -> Text
grantName = \case GrantConnect -> "CONNECT"; GrantCreate -> "CREATE"; GrantTemporary -> "TEMPORARY"

adminTarget :: HinagataConfig -> DatabaseName -> Either AccessError ConnectionTarget
adminTarget configuration = accessToTarget configuration (administration configuration)

accessToTarget :: HinagataConfig -> AccessConfig -> DatabaseName -> Either AccessError ConnectionTarget
accessToTarget HinagataConfig {endpoint = EndpointConfig {host, port}} AccessConfig {user, password} database =
  either (Left . (\message -> AccessError message Nothing)) Right (mkConnectionTarget host port user database password)

quoteDatabase :: DatabaseName -> Text
quoteDatabase = (\value -> "\"" <> Text.replace "\"" "\"\"" value <> "\"") . databaseNameText

quoteRole :: Text -> Either AccessError Text
quoteRole role = either (Left . (\message -> AccessError message Nothing)) (Right . quoteSqlIdentifier) (mkSqlIdentifier role)

quoteLiteral :: Text -> Text
quoteLiteral value = "'" <> Text.replace "'" "''" value <> "'"

accessNativeFailure :: NativeError -> AccessError
accessNativeFailure NativeError {reason, sqlState} = AccessError reason sqlState

accessSessionFailure :: SessionError -> AccessError
accessSessionFailure failure = AccessError (Text.pack (show failure)) Nothing
