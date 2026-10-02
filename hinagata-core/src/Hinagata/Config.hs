-- | Pure, inspectable Settei declarations for Hinagata's shared settings.
-- Sources are supplied explicitly by the caller; this module performs no IO.
module Hinagata.Config
  ( HinagataConfig (..),
    EndpointConfig (..),
    AccessConfig (..),
    DatabaseGrant (..),
    SchemaPrivilege (..),
    SchemaGrant (..),
    RoleSetting (..),
    CloneStrategy (..),
    accessTarget,
    hinagataConfig,
    hinagataEnvironmentBindings,
  )
where

import Data.Text qualified as Text
import Hinagata.Connection
import Hinagata.Prelude
import Hinagata.Types
import Settei qualified
import Settei.Env qualified as Env
import System.FilePath (isAbsolute)

-- | Connection transport shared by the three independently declared roles.
data EndpointConfig = EndpointConfig
  { host :: !Host,
    port :: !Port
  }
  deriving stock (Eq, Show)

-- | One explicitly selected role and database. Passwords remain secret-safe.
data AccessConfig = AccessConfig
  { user :: !Text,
    database :: !DatabaseName,
    password :: !(Maybe Secret)
  }
  deriving stock (Eq)

instance Show AccessConfig where
  show AccessConfig {user, database} =
    "AccessConfig {user = " ++ show user ++ ", database = " ++ show database ++ ", password = <redacted>}"

-- | The only database-level privileges that the lifecycle layer may apply.
data DatabaseGrant = GrantConnect | GrantCreate | GrantTemporary
  deriving stock (Eq, Ord, Show)

data SchemaPrivilege = SchemaUsage | SchemaCreate
  deriving stock (Eq, Ord, Show)

data SchemaGrant = SchemaGrant
  { schema :: !SqlIdentifier,
    privilege :: !SchemaPrivilege
  }
  deriving stock (Eq, Show)

-- | A declared database-level role setting. Its value is configuration, never SQL text.
data RoleSetting = RoleSetting
  { name :: !SqlIdentifier,
    value :: !Text
  }
  deriving stock (Eq, Show)

data CloneStrategy = WalLog | FileCopy
  deriving stock (Eq, Ord, Show)

-- | All limits are local to one suite-scoped manager.
data HinagataConfig = HinagataConfig
  { endpoint :: !EndpointConfig,
    project :: !ProjectId,
    fixtureRoot :: !FilePath,
    bundleRoot :: !FilePath,
    maintenanceDatabase :: !DatabaseName,
    maintenanceSchema :: !SqlIdentifier,
    administration :: !AccessConfig,
    setup :: !AccessConfig,
    application :: !AccessConfig,
    setupGrants :: ![DatabaseGrant],
    applicationGrants :: ![DatabaseGrant],
    setupSchemaGrants :: ![SchemaGrant],
    applicationSchemaGrants :: ![SchemaGrant],
    setupSettings :: ![RoleSetting],
    applicationSettings :: ![RoleSetting],
    cloneStrategy :: !CloneStrategy,
    acquisitionDeadlineMs :: !Positive,
    setupDeadlineMs :: !Positive,
    setupWorkers :: !Positive,
    activeLeases :: !Positive,
    pendingRequests :: !Positive,
    chunkSize :: !Positive,
    sqlSizeLimit :: !Positive
  }
  deriving stock (Eq, Show)

-- | Recheck the target invariant when turning a resolved access description into
-- a libpq target. The resolver's user decoder already guarantees this succeeds.
accessTarget :: EndpointConfig -> AccessConfig -> Either Text ConnectionTarget
accessTarget EndpointConfig {host, port} AccessConfig {user, database, password} =
  mkConnectionTarget host port user database password

hinagataConfig :: Settei.Config HinagataConfig
hinagataConfig =
  HinagataConfig
    <$> endpointConfig
    <*> required "project.id" "Project identity used in owned database names" projectDecoder
    <*> required "fixture.root" "Absolute fixture source directory" directoryDecoder
    <*> required "bundle.root" "Absolute private bundle cache directory" directoryDecoder
    <*> required "maintenance.database" "Existing maintenance database" databaseDecoder
    <*> defaulted "maintenance.schema" "Maintenance catalog schema" identifierDecoder "maintenance-schema" "Use a dedicated catalog schema" (knownIdentifier "hinagata")
    <*> accessConfig "administration"
    <*> accessConfig "setup"
    <*> accessConfig "application"
    <*> defaulted "setup.grants" "Database grants for setup role" grantsDecoder "setup-grants" "Allow setup migration and fixture creation" [GrantConnect, GrantCreate, GrantTemporary]
    <*> defaulted "application.grants" "Database grants for application role" grantsDecoder "application-grants" "Application connects without schema creation" [GrantConnect]
    <*> defaulted "setup.schema_grants" "Schema grants for setup role" schemaGrantsDecoder "setup-schema-grants" "Permit migrations in public" [SchemaGrant (knownIdentifier "public") SchemaUsage, SchemaGrant (knownIdentifier "public") SchemaCreate]
    <*> defaulted "application.schema_grants" "Schema grants for application role" schemaGrantsDecoder "application-schema-grants" "Permit application access to public" [SchemaGrant (knownIdentifier "public") SchemaUsage]
    <*> defaulted "setup.settings" "Database-level setup role settings" settingsDecoder "setup-settings" "No extra role settings" []
    <*> defaulted "application.settings" "Database-level application role settings" settingsDecoder "application-settings" "No extra role settings" []
    <*> defaulted "clone.strategy" "PostgreSQL clone strategy" (Settei.enumDecoder [("WAL_LOG", WalLog), ("FILE_COPY", FileCopy)]) "clone-strategy" "WAL_LOG is the portable default" WalLog
    <*> positiveDefault "limits.acquisition_deadline_ms" "Acquisition deadline in milliseconds" 30000
    <*> positiveDefault "limits.setup_deadline_ms" "Setup deadline in milliseconds" 300000
    <*> positiveDefault "limits.setup_workers" "Manager-local concurrent setup workers" 2
    <*> positiveDefault "limits.active_leases" "Manager-local active leases" 8
    <*> positiveDefault "limits.pending_requests" "Manager-local queued acquisition requests" 32
    <*> positiveDefault "limits.chunk_size" "CSV transfer chunk bytes" 65536
    <*> positiveDefault "limits.sql_size_limit" "Maximum SQL step bytes" 1048576

endpointConfig :: Settei.Config EndpointConfig
endpointConfig =
  EndpointConfig
    <$> required "endpoint.host" "Absolute socket directory or TCP hostname" hostDecoder
    <*> required "endpoint.port" "PostgreSQL listener port" portDecoder

accessConfig :: Text -> Settei.Config AccessConfig
accessConfig prefix =
  AccessConfig
    <$> required (prefix <> ".user") "Explicit database role" userDecoder
    <*> required (prefix <> ".database") "Explicit database for this role" databaseDecoder
    <*> Settei.optional (Settei.secretSetting (key (prefix <> ".password")) "Optional role password" secretDecoder)

-- | Explicit bindings only. Invalid static names or key collisions are returned
-- to the caller and can be forced in startup tests before reading the environment.
hinagataEnvironmentBindings :: Either (NonEmpty Env.EnvError) Env.Bindings
hinagataEnvironmentBindings =
  Env.bindings
    [ Env.binding (Env.EnvName ("HINAGATA_" <> Text.toUpper (Text.replace "." "_" name))) (key name)
    | name <- settingNames
    ]

settingNames :: [Text]
settingNames =
  [ "endpoint.host",
    "endpoint.port",
    "project.id",
    "fixture.root",
    "bundle.root",
    "maintenance.database",
    "maintenance.schema",
    "administration.user",
    "administration.database",
    "administration.password",
    "setup.user",
    "setup.database",
    "setup.password",
    "application.user",
    "application.database",
    "application.password",
    "setup.grants",
    "application.grants",
    "setup.schema_grants",
    "application.schema_grants",
    "setup.settings",
    "application.settings",
    "clone.strategy",
    "limits.acquisition_deadline_ms",
    "limits.setup_deadline_ms",
    "limits.setup_workers",
    "limits.active_leases",
    "limits.pending_requests",
    "limits.chunk_size",
    "limits.sql_size_limit"
  ]

required :: Text -> Text -> Settei.Decoder a -> Settei.Config a
required name description valueDecoder = Settei.required (Settei.publicSetting (key name) description valueDecoder)

defaulted :: (Show a) => Text -> Text -> Settei.Decoder a -> Text -> Text -> a -> Settei.Config a
defaulted name description valueDecoder rule explanation value =
  Settei.withDefault
    (Settei.publicShowSetting (key name) description valueDecoder)
    (Settei.constantDefault (Settei.RuleName rule) explanation value)

positiveDefault :: Text -> Text -> Int -> Settei.Config Positive
positiveDefault name description value =
  defaulted name description (positiveDecoder name) (name <> "-default") "Manager-local operational default" (knownPositive value)

key :: Text -> Settei.Key
key name = case Settei.parseKey name of
  Right result -> result
  Left problem -> error ("Invalid static Hinagata setting key: " ++ show problem)

knownPositive :: Int -> Positive
knownPositive value = case mkPositive "built-in limit" value of
  Right result -> result
  Left problem -> error (Text.unpack problem)

knownIdentifier :: Text -> SqlIdentifier
knownIdentifier value = case mkSqlIdentifier value of
  Right result -> result
  Left problem -> error (Text.unpack problem)

hostDecoder :: Settei.Decoder Host
hostDecoder = Settei.parsedDecoder "an absolute socket directory or TCP hostname" $ \value ->
  if Text.isPrefixOf "/" value then socketDirectory value else tcpHost value

portDecoder :: Settei.Decoder Port
portDecoder = Settei.decoder $ \settingKey raw -> do
  value <- Settei.runDecoder Settei.boundedIntegralDecoder settingKey raw
  either (const (Left (Settei.decodeFailure settingKey "port between 1 and 65535"))) Right (mkPort value)

projectDecoder :: Settei.Decoder ProjectId
projectDecoder = Settei.parsedDecoder "a lowercase project ID" mkProjectId

databaseDecoder :: Settei.Decoder DatabaseName
databaseDecoder = Settei.parsedDecoder "a PostgreSQL database name of at most 63 UTF-8 bytes" mkDatabaseName

identifierDecoder :: Settei.Decoder SqlIdentifier
identifierDecoder = Settei.parsedDecoder "a PostgreSQL identifier of at most 63 UTF-8 bytes" mkSqlIdentifier

directoryDecoder :: Settei.Decoder FilePath
directoryDecoder = Settei.parsedDecoder "an absolute directory path without NUL" $ \value ->
  if not (Text.null value) && not (Text.any (== '\0') value) && isAbsolute (Text.unpack value)
    then Right (Text.unpack value)
    else Left "invalid directory"

userDecoder :: Settei.Decoder Text
userDecoder = Settei.parsedDecoder "a nonempty database role without NUL" $ \value ->
  if Text.null value || Text.any (== '\0') value then Left "invalid user" else Right value

secretDecoder :: Settei.Decoder Secret
secretDecoder = Settei.parsedDecoder "a password without NUL" mkSecret

positiveDecoder :: Text -> Settei.Decoder Positive
positiveDecoder name = Settei.decoder $ \settingKey raw -> do
  value <- Settei.runDecoder Settei.boundedIntegralDecoder settingKey raw
  either (const (Left (Settei.decodeFailure settingKey "a positive integer"))) Right (mkPositive name value)

grantsDecoder :: Settei.Decoder [DatabaseGrant]
grantsDecoder = Settei.decoder $ \settingKey raw ->
  case scalarList raw of
    Nothing -> Left (Settei.decodeFailure settingKey "a comma-separated or array grant list")
    Just names -> traverse (parseGrant settingKey) names

parseGrant :: Settei.Key -> Text -> Either Settei.DecodeFailure DatabaseGrant
parseGrant settingKey value = case Text.toUpper (Text.strip value) of
  "CONNECT" -> Right GrantConnect
  "CREATE" -> Right GrantCreate
  "TEMPORARY" -> Right GrantTemporary
  _ -> Left (Settei.decodeFailure settingKey "CONNECT, CREATE, or TEMPORARY grants")

schemaGrantsDecoder :: Settei.Decoder [SchemaGrant]
schemaGrantsDecoder = Settei.decoder $ \settingKey raw ->
  case scalarList raw of
    Nothing -> Left (Settei.decodeFailure settingKey "a comma-separated or array schema grant list")
    Just values -> traverse (parseSchemaGrant settingKey) values

parseSchemaGrant :: Settei.Key -> Text -> Either Settei.DecodeFailure SchemaGrant
parseSchemaGrant settingKey value =
  case Text.breakOn ":" value of
    (schemaName, assigned)
      | not (Text.null assigned),
        Right schema <- mkSqlIdentifier (Text.strip schemaName) ->
          case Text.toUpper (Text.strip (Text.drop 1 assigned)) of
            "USAGE" -> Right SchemaGrant {schema, privilege = SchemaUsage}
            "CREATE" -> Right SchemaGrant {schema, privilege = SchemaCreate}
            _ -> invalid
    _ -> invalid
  where
    invalid = Left (Settei.decodeFailure settingKey "SCHEMA:USAGE or SCHEMA:CREATE grant")

settingsDecoder :: Settei.Decoder [RoleSetting]
settingsDecoder = Settei.decoder $ \settingKey raw ->
  case scalarList raw of
    Nothing -> Left (Settei.decodeFailure settingKey "a comma-separated or array setting list")
    Just values -> traverse (parseRoleSetting settingKey) values

parseRoleSetting :: Settei.Key -> Text -> Either Settei.DecodeFailure RoleSetting
parseRoleSetting settingKey value =
  case Text.breakOn "=" value of
    (settingName, assigned)
      | not (Text.null assigned),
        Right name <- mkSqlIdentifier (Text.strip settingName),
        let settingValue = Text.strip (Text.drop 1 assigned),
        not (Text.any (== '\0') settingValue) ->
          Right RoleSetting {name, value = settingValue}
    _ -> Left (Settei.decodeFailure settingKey "NAME=VALUE database setting")

scalarList :: Settei.RawValue -> Maybe [Text]
scalarList (Settei.RawText value)
  | Text.null (Text.strip value) = Just []
  | otherwise = Just (Text.splitOn "," value)
scalarList (Settei.RawArray values) = traverse textValue values
  where
    textValue (Settei.RawText value) = Just value
    textValue _ = Nothing
scalarList _ = Nothing
