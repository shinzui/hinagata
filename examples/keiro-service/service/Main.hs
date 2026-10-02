module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Counter (addCounter, counterTotal)
import Data.Aeson qualified as Json
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import Hinagata.Connection
import Hinagata.Types (mkDatabaseName, mkPort)
import Kiroku.Store qualified as Store
import Network.HTTP.Types (hContentType, methodGet, methodPost, status200, status201, status400, status404, status500)
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
      connectionText = connectionStringText (renderConnectionString target)
  Store.withStore (Store.defaultConnectionSettings connectionText) $ \store ->
    Warp.runSettings server (application target store)

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

application :: ConnectionTarget -> Store.KirokuStore -> Wai.Application
application target store request respond = do
  response <- case (Wai.requestMethod request, Wai.pathInfo request) of
    (method, ["health"]) | method == methodGet -> do
      role <- query target "SELECT current_user"
      pure $ case role of
        Just selected -> json status200 (Json.object ["ok" Json..= True, "role" Json..= Encoding.decodeUtf8 selected])
        _ -> json status500 (Json.object ["error" Json..= ("database_unavailable" :: Text.Text)])
    (method, ["hold"]) | method == methodGet -> do
      threadDelay 60000000
      pure (json status200 (Json.object ["ok" Json..= True]))
    (method, ["references"]) | method == methodGet -> do
      references <- query target "SELECT coalesce(json_agg(json_build_object('id', id, 'code', code, 'label', label) ORDER BY id)::text, '[]') FROM public.keiro_reference_data"
      pure $ maybe (json status500 (Json.object ["error" Json..= ("database_unavailable" :: Text.Text)])) (rawJson status200 . Lazy.fromStrict) references
    (method, ["references", "new"]) | method == methodPost -> do
      inserted <- query target "INSERT INTO public.keiro_reference_data (code, label) VALUES ('generated', 'Generated') RETURNING id::text"
      pure $ maybe (json status500 (Json.object ["error" Json..= ("insert_failed" :: Text.Text)])) (json status201 . Json.object . pure . ("id" Json..=) . Encoding.decodeUtf8) inserted
    (method, ["references", _]) | method == methodGet -> pure (json status404 (Json.object ["error" Json..= ("reference_not_found" :: Text.Text)]))
    (method, ["counters", counterId, "add"])
      | method == methodPost ->
          if validCounterId counterId
            then do
              appended <- addCounter store counterId
              pure $ if appended then json status201 (Json.object ["appended" Json..= True]) else json status500 (Json.object ["error" Json..= ("command_failed" :: Text.Text)])
            else pure (json status400 (Json.object ["error" Json..= ("invalid_counter_id" :: Text.Text)]))
    (method, ["counters", counterId])
      | method == methodGet ->
          if validCounterId counterId
            then do
              total <- counterTotal store counterId
              pure $ maybe (json status500 (Json.object ["error" Json..= ("read_failed" :: Text.Text)])) (json status200 . Json.object . pure . ("total" Json..=)) total
            else pure (json status400 (Json.object ["error" Json..= ("invalid_counter_id" :: Text.Text)]))
    _ -> pure (json status404 (Json.object ["error" Json..= ("route_not_found" :: Text.Text)]))
  respond response
  where
    json status body = rawJson status (Json.encode body)
    rawJson status body = Wai.responseLBS status [(hContentType, "application/json; charset=utf-8")] body

validCounterId :: Text.Text -> Bool
validCounterId value = not (Text.null value) && Text.length value <= 32 && Text.all (\character -> character >= 'a' && character <= 'z') value

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
