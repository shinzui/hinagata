module Main (main) where

import Control.Monad (forM_)
import Data.ByteString.Char8 qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import GHC.Clock (getMonotonicTimeNSec)
import Hinagata.Connection
import Hinagata.Fixture.Bundle
import Hinagata.Fixture.Types
import Hinagata.Postgres.Load
import Hinagata.Postgres.Session
import Hinagata.Prelude
import Hinagata.Types
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, getEnv)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), withBinaryFile)
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = do
  rows <-
    getArgs >>= \case
      [value] -> pure (read value)
      _ -> fail "usage: hinagata-postgres-direct-load ROWS"
  socket <- getEnv "HINAGATA_TEST_PGHOST"
  portText <- getEnv "HINAGATA_TEST_PGPORT"
  user <- getEnv "HINAGATA_TEST_PGUSER"
  databaseText <- getEnv "HINAGATA_TEST_PGDATABASE"
  host <- orFail (socketDirectory (Text.pack socket))
  port <- orFail (mkPort (read portText))
  database <- orFail (mkDatabaseName (Text.pack databaseText))
  target <- orFail (mkConnectionTarget host port (Text.pack user) database Nothing)
  withSystemTempDirectory "hinagata-load-bench-" $ \workspace -> do
    let fixtureRoot = workspace </> "fixtures"
        fixtureDirectory = fixtureRoot </> "bulk"
        tableName = "hinagata_bench_" ++ show rows
        config = BundleConfig fixtureRoot (workspace </> "bundles") (positive 1048576) (positive 65536)
    createDirectoryIfMissing True fixtureDirectory
    ByteString.writeFile (fixtureDirectory </> "fixture.yaml") (ByteString.pack ("name: bulk\nsteps:\n  - sql: schema.sql\n  - copy:\n      table: {schema: public, name: " ++ tableName ++ "}\n      columns: [id, payload]\n      file: rows.csv\n      format: csv\n      header: false\n"))
    ByteString.writeFile (fixtureDirectory </> "schema.sql") (ByteString.pack ("CREATE TABLE " ++ tableName ++ " (id integer PRIMARY KEY, payload text NOT NULL);"))
    generateStart <- getMonotonicTimeNSec
    withBinaryFile (fixtureDirectory </> "rows.csv") WriteMode $ \handle ->
      forM_ [1, 1001 .. rows] $ \first ->
        ByteString.hPut handle (ByteString.pack (concatMap (\n -> show n ++ ",payload\n") [first .. min rows (first + 999)]))
    generateEnd <- getMonotonicTimeNSec
    plan <- orFail =<< compileFixtures config [fixtureName "bulk"]
    compileEnd <- getMonotonicTimeNSec
    report <- orFail =<< loadInto target defaultSessionOptions plan
    loadEnd <- getMonotonicTimeNSec
    connection <- PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString target)))
    found <- queryCount connection tableName
    PQ.finish connection
    unless (found == rows) (fail "loaded row count differs from input")
    putStrLn $
      unwords
        [ "rows=" ++ show rows,
          "generate_ms=" ++ show ((generateEnd - generateStart) `div` 1000000),
          "compile_ms=" ++ show ((compileEnd - generateEnd) `div` 1000000),
          "load_ms=" ++ show ((loadEnd - compileEnd) `div` 1000000),
          "copy_ms=" ++ show (copyMs report),
          "verify_ms=" ++ show (verifyMs report),
          "bytes=" ++ show (bytesSent report),
          "rows_per_second=" ++ show (if elapsedMs report == 0 then 0 else fromIntegral rows * 1000 `div` fromIntegral (elapsedMs report) :: Int)
        ]

queryCount :: PQ.Connection -> String -> IO Int
queryCount connection tableName = do
  result <- PQ.exec connection (ByteString.pack ("SELECT count(*) FROM " ++ tableName))
  case result of
    Nothing -> fail "count query returned no result"
    Just value -> do
      cell <- PQ.getvalue value (PQ.toRow (0 :: Int)) (PQ.toColumn (0 :: Int))
      maybe (fail "count query returned NULL") (pure . read . ByteString.unpack) cell

fixtureName :: Text -> FixtureName
fixtureName = either (error . Text.unpack) id . mkFixtureName

positive :: Int -> Positive
positive = either (error . Text.unpack) id . mkPositive "bench limit"

orFail :: (Show e) => Either e a -> IO a
orFail = either (fail . show) pure
