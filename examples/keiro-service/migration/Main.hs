module Main (main) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.:))
import Data.ByteString.Char8 qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import Database.PostgreSQL.Migrate
  ( MigrationPlan,
    VerificationReport (..),
    defaultRunOptions,
    migrationComponent,
    migrationPlan,
    runMigrationPlan,
    sqlMigration,
    verifyMigrationPlan,
  )
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations (keiroMigrations)
import Kiroku.Store.Migrations (kirokuMigrations)
import System.Environment (getArgs, getEnv)
import System.Exit (die)
import System.FilePath (isAbsolute, splitDirectories, takeDirectory, (</>))
import Text.Read (readMaybe)

main :: IO ()
main = do
  (identifier, applicationSql, marker) <- readApplicationInputs
  plan <- either (const (die "invalid composed migration plan")) pure (composedPlan identifier applicationSql)
  settings <- connectionSettings
  getArgs >>= \case
    ["up"] -> do
      result <- runMigrationPlan defaultRunOptions settings plan
      either (die . show) (const (putStrLn "migration plan applied")) result
    ["verify"] -> do
      verifyLedger settings plan
      verifyLiveSchema marker
    ["verify-ledger"] -> verifyLedger settings plan
    ["verify-live"] -> verifyLiveSchema marker
    _ -> die "usage: hinagata-keiro-migrate up|verify|verify-ledger|verify-live"

verifyLedger :: Settings.Settings -> MigrationPlan -> IO ()
verifyLedger settings plan = do
  result <- verifyMigrationPlan defaultRunOptions settings plan
  case result of
    Left failure -> die (show failure)
    Right VerificationReport {issues = [], pendingMigrations = []} -> putStrLn "migration ledger verified"
    Right report -> die ("migration ledger differs from the complete plan: " ++ show report)

verifyLiveSchema :: Text.Text -> IO ()
verifyLiveSchema marker =
  bracket (PQ.connectdb "") PQ.finish $ \connection -> do
    status <- PQ.status connection
    if status /= PQ.ConnectionOk
      then die "live schema verification could not connect"
      else do
        let statement =
              ByteString.unlines
                [ "SELECT to_regclass('public.keiro_reference_data') IS NOT NULL",
                  "  AND (SELECT is_identity = 'YES' FROM information_schema.columns",
                  "       WHERE table_schema = 'public' AND table_name = 'keiro_reference_data' AND column_name = 'id')",
                  "  AND has_table_privilege('hinagata_example_app', 'public.keiro_reference_data', 'SELECT')",
                  "  AND has_table_privilege('hinagata_example_app', 'public.keiro_reference_data', 'INSERT')",
                  "  AND obj_description('public.keiro_reference_data'::regclass) = " <> quoteLiteral marker
                ]
        executed <- PQ.exec connection statement
        case executed of
          Nothing -> die "live schema verification returned no result"
          Just result -> do
            resultStatus <- PQ.resultStatus result
            if resultStatus /= PQ.TuplesOk
              then die "live schema verification query failed"
              else do
                value <- PQ.getvalue result (PQ.toRow (0 :: Int)) (PQ.toColumn (0 :: Int))
                if value == Just "t" then putStrLn "application live schema verified" else die "application live schema differs from its declared contract"

data ApplicationManifest = ApplicationManifest !Text.Text !FilePath

instance FromJSON ApplicationManifest where
  parseJSON = withObject "application migration manifest" $ \object ->
    ApplicationManifest <$> object .: "id" <*> object .: "sql"

readApplicationInputs :: IO (Text.Text, ByteString.ByteString, Text.Text)
readApplicationInputs = do
  manifestPath <- getEnv "EXAMPLE_MIGRATION_MANIFEST"
  marker <- Text.pack <$> getEnv "EXAMPLE_SCHEMA_MARKER"
  unless (not (Text.any (== '\0') marker)) (die "invalid schema marker")
  bytes <- readInput manifestPath
  ApplicationManifest identifier sqlPath <- either (const (die "invalid application migration manifest")) pure (eitherDecodeStrict bytes)
  unless (not (Text.null identifier) && Text.all (\c -> c `elem` ("abcdefghijklmnopqrstuvwxyz0123456789-_" :: String)) identifier) (die "invalid application migration id")
  unless (not (null sqlPath) && not (isAbsolute sqlPath) && '\0' `notElem` sqlPath && all (`notElem` [".", ".."]) (splitDirectories sqlPath)) (die "invalid application SQL location")
  sql <- readInput (takeDirectory manifestPath </> sqlPath)
  pure (identifier, sql <> "\nCOMMENT ON TABLE public.keiro_reference_data IS " <> quoteLiteral marker <> ";\n", marker)
  where
    readInput path = try @IOException (ByteString.readFile path) >>= either (const (die "application migration input cannot be read")) pure

quoteLiteral :: Text.Text -> ByteString.ByteString
quoteLiteral value = "E'" <> Encoding.encodeUtf8 (Text.replace "'" "''" (Text.replace "\\" "\\\\" value)) <> "'"

composedPlan :: Text.Text -> ByteString.ByteString -> Either String MigrationPlan
composedPlan identifier applicationSql = do
  kiroku <- either (Left . show) Right kirokuMigrations
  keiro <- either (Left . show) Right keiroMigrations
  applicationMigration <- either (Left . show) Right (sqlMigration identifier applicationSql)
  application <- either (Left . show) Right (migrationComponent "hinagata-keiro-example" (Set.singleton "keiro") (applicationMigration :| []))
  either (Left . show) Right (migrationPlan (kiroku :| [keiro, application]))

connectionSettings :: IO Settings.Settings
connectionSettings = do
  host <- Text.pack <$> getEnv "PGHOST"
  portText <- getEnv "PGPORT"
  port <- maybe (die "PGPORT must be a port number") pure (readMaybe portText :: Maybe Word)
  if port == 0 || port > 65535 then die "PGPORT is out of range" else pure ()
  user <- Text.pack <$> getEnv "PGUSER"
  database <- Text.pack <$> getEnv "PGDATABASE"
  pure (Settings.hostAndPort host (fromIntegral port) <> Settings.user user <> Settings.dbname database)
