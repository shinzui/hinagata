module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (bracket)
import Control.Monad (forM)
import Data.Aeson qualified as Json
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import GHC.Clock (getMonotonicTimeNSec)
import Hinagata.Config
import Hinagata.Connection
import Hinagata.Fixture.Bundle
import Hinagata.Fixture.Types (mkFixtureName)
import Hinagata.Postgres.Baseline
import Hinagata.Postgres.Lease
import Hinagata.Postgres.Manager
import Hinagata.Prelude
import Hinagata.Types
import System.Environment (getArgs, getEnv)

main :: IO ()
main = do
  count <-
    getArgs >>= \case
      [value] -> pure (read value :: Int)
      _ -> fail "usage: hinagata-postgres-concurrent-leases COUNT"
  unless (count `elem` [1, 4, 8]) (fail "COUNT must be 1, 4, or 8")
  socket <- Text.pack <$> getEnv "HINAGATA_TEST_PGHOST"
  portText <- getEnv "HINAGATA_TEST_PGPORT"
  user <- Text.pack <$> getEnv "HINAGATA_TEST_PGUSER"
  databaseText <- Text.pack <$> getEnv "HINAGATA_TEST_PGDATABASE"
  fixtureRoot <- getEnv "BENCH_FIXTURE_ROOT"
  bundleRoot <- getEnv "BENCH_BUNDLE_ROOT"
  host <- orFail (socketDirectory socket)
  port <- orFail (mkPort (read portText))
  database <- orFail (mkDatabaseName databaseText)
  project <- orFail (mkProjectId "benchmark-concurrency")
  catalogSchema <- orFail (mkSqlIdentifier "hinagata")
  publicSchema <- orFail (mkSqlIdentifier "public")
  fixture <- orFail (mkFixtureName "bulk-base")
  let role = AccessConfig user database Nothing
      configuration =
        HinagataConfig
          { endpoint = EndpointConfig host port,
            project,
            fixtureRoot,
            bundleRoot,
            maintenanceDatabase = database,
            maintenanceSchema = catalogSchema,
            administration = role,
            setup = role,
            application = role,
            setupGrants = [GrantConnect, GrantCreate, GrantTemporary],
            applicationGrants = [GrantConnect],
            setupSchemaGrants = [SchemaGrant publicSchema SchemaUsage, SchemaGrant publicSchema SchemaCreate],
            applicationSchemaGrants = [SchemaGrant publicSchema SchemaUsage],
            setupSettings = [],
            applicationSettings = [],
            cloneStrategy = WalLog,
            acquisitionDeadlineMs = positive 300000,
            setupDeadlineMs = positive 300000,
            setupWorkers = positive 4,
            activeLeases = positive 8,
            pendingRequests = positive 16,
            chunkSize = positive 65536,
            sqlSizeLimit = positive 1048576
          }
  plan <- orFail =<< compileFixtures (BundleConfig fixtureRoot bundleRoot (positive 1048576) (positive 65536)) [fixture]
  let noop _ = pure (Right ())
      specification = BaselineSpec configuration plan (Just "benchmark-noop-v1") (Just "benchmark-noop-v1") [] Nothing noop noop Nothing Nothing
  (baseline, _) <- orFail =<< ensureBaseline specification
  started <- getMonotonicTimeNSec
  outcomes <- withManager configuration $ \manager ->
    Async.mapConcurrently
      ( \_ -> do
          requestStart <- getMonotonicTimeNSec
          result <- withManagedDatabaseClassified manager baseline plan ReleaseAlways (const False) $ \info -> do
            callbackStart <- getMonotonicTimeNSec
            bracket
              (PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString (applicationTarget info)))))
              PQ.finish
              ( \connection -> do
                  status <- PQ.status connection
                  unless (status == PQ.ConnectionOk) (fail "application pool connection failed")
                  threadDelay 50000
              )
            pure callbackStart
          requestEnd <- getMonotonicTimeNSec
          pure (requestStart, requestEnd, result)
      )
      [1 .. count]
  ended <- getMonotonicTimeNSec
  timings <- forM outcomes $ \(requestStart, requestEnd, result) -> case result of
    Left problem -> fail ("lease failed: " ++ show problem)
    Right LeaseOutcome {callbackValue, leaseDisposition = LeaseReleased, cleanupDiagnostic = Nothing, timings = LeaseTimings {queueWaitMs, catalogMs, generationLockMs, cloneMs, scenarioLoadMs, completionMs}} ->
      pure $ Json.object ["requestMs" Json..= ((requestEnd - requestStart) `div` 1000000), "callbackStartNs" Json..= callbackValue, "queueWaitMs" Json..= queueWaitMs, "catalogMs" Json..= catalogMs, "generationLockMs" Json..= generationLockMs, "cloneMs" Json..= cloneMs, "scenarioLoadMs" Json..= scenarioLoadMs, "completionMs" Json..= completionMs]
    Right other -> fail ("lease cleanup failed: " ++ show other)
  Lazy.putStrLn (Json.encode (Json.object ["concurrency" Json..= count, "elapsedMs" Json..= ((ended - started) `div` 1000000), "timings" Json..= timings]))

positive :: Int -> Positive
positive = either (error . Text.unpack) id . mkPositive "benchmark limit"

orFail :: (Show e) => Either e a -> IO a
orFail = either (fail . show) pure
