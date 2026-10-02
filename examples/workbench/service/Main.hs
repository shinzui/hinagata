module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import Hinagata.Connection
import Hinagata.Types (mkDatabaseName, mkPort)
import Network.HTTP.Types (hContentType, methodGet, status200, status404, status500)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Settei qualified
import Settei.Env qualified as Env
import System.Environment (getEnvironment)
import Text.Read (readMaybe)

data ServiceConfig = ServiceConfig
  { httpPort :: !Int,
    databaseHost :: !Text.Text,
    databasePort :: !Int,
    databaseUser :: !Text.Text,
    databaseName :: !Text.Text
  }

main :: IO ()
main = do
  settings <- resolveSettings
  ServiceConfig {httpPort, databaseHost, databasePort, databaseUser, databaseName} <- either (fail . Text.unpack) pure settings
  host <- either (fail . Text.unpack) pure (if "/" `Text.isPrefixOf` databaseHost then socketDirectory databaseHost else tcpHost databaseHost)
  port <- either (fail . Text.unpack) pure (mkPort databasePort)
  database <- either (fail . Text.unpack) pure (mkDatabaseName databaseName)
  target <- either (fail . Text.unpack) pure (mkConnectionTarget host port databaseUser database Nothing)
  let server = Warp.setHost "127.0.0.1" (Warp.setPort httpPort Warp.defaultSettings)
  Warp.runSettings server (application target)

resolveSettings :: IO (Either Text.Text ServiceConfig)
resolveSettings = do
  let bindingNames =
        [ ("SERVICE_PORT", "service.port"),
          ("SERVICE_PGHOST", "service.database.host"),
          ("SERVICE_PGPORT", "service.database.port"),
          ("SERVICE_PGUSER", "service.database.user"),
          ("SERVICE_PGDATABASE", "service.database.name")
        ]
      parsedKey name = either (error . show) id (Settei.parseKey name)
      declared = Env.bindings [Env.binding (Env.EnvName environmentName) (parsedKey settingName) | (environmentName, settingName) <- bindingNames]
  case declared of
    Left problems -> pure (Left (Env.renderEnvErrorsText problems))
    Right bindings -> do
      environment <- getEnvironment
      let snapshot = Env.envSnapshot [(Text.pack key, Text.pack value) | (key, value) <- environment]
          Settei.ResolveResult {answer} = Settei.resolve Settei.defaultResolveOptions [Env.environmentSource bindings snapshot] serviceConfig
      pure (either (Left . Settei.renderErrorsText) Right answer)

serviceConfig :: Settei.Config ServiceConfig
serviceConfig =
  ServiceConfig
    <$> number "service.port" "HTTP listener port"
    <*> text "service.database.host" "PostgreSQL socket directory or host"
    <*> number "service.database.port" "PostgreSQL port"
    <*> text "service.database.user" "Application database role"
    <*> text "service.database.name" "Lease database name"
  where
    text name description = Settei.required (Settei.publicSetting (settingKey name) description Settei.textDecoder)
    number name description = Settei.required (Settei.publicSetting (settingKey name) description portDecoder)
    settingKey name = either (error . show) id (Settei.parseKey name)
    portDecoder = Settei.parsedDecoder "TCP port between 1 and 65535" $ \value ->
      case readMaybe (Text.unpack value) of
        Just port | port > 0 && port <= 65535 -> Right port
        _ -> Left "port must be between 1 and 65535"

application :: ConnectionTarget -> Wai.Application
application target request respond = do
  response <- case (Wai.requestMethod request, Wai.pathInfo request) of
    (method, ["health"]) | method == methodGet -> do
      checked <- query target "SELECT 1"
      pure $ case checked of
        Just "1" -> json status200 "{\"ok\":true}"
        _ -> json status500 "{\"error\":\"database_unavailable\"}"
    (method, ["members"]) | method == methodGet -> do
      members <- query target "SELECT coalesce(json_agg(json_build_object('id', id, 'name', name) ORDER BY id)::text, '[]') FROM members"
      pure $ maybe (json status500 "{\"error\":\"database_unavailable\"}") (json status200 . Lazy.fromStrict) members
    (method, ["members", _]) | method == methodGet -> pure (json status404 "{\"error\":\"member_not_found\"}")
    (method, ["slow"]) | method == methodGet -> do
      threadDelay 30000000
      checked <- query target "SELECT 1"
      pure $ case checked of
        Just "1" -> json status200 "{\"ok\":true}"
        _ -> json status500 "{\"error\":\"database_unavailable\"}"
    _ -> pure (json status404 "{\"error\":\"route_not_found\"}")
  respond response
  where
    json status body = Wai.responseLBS status [(hContentType, "application/json; charset=utf-8")] body

query :: ConnectionTarget -> ByteString.ByteString -> IO (Maybe ByteString.ByteString)
query target statement =
  bracket
    (PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString target))))
    PQ.finish
    ( \connection -> do
        connectionStatus <- PQ.status connection
        if connectionStatus /= PQ.ConnectionOk
          then pure Nothing
          else do
            executed <- PQ.exec connection statement
            case executed of
              Nothing -> pure Nothing
              Just result -> do
                resultStatus <- PQ.resultStatus result
                if resultStatus /= PQ.TuplesOk then pure Nothing else PQ.getvalue result (PQ.toRow (0 :: Int)) (PQ.toColumn (0 :: Int))
    )
