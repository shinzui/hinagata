module Main (main) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Data.ByteString.Char8 qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import Hinagata.Connection
import Hinagata.Fixture.Bundle
import Hinagata.Fixture.Types
import Hinagata.Postgres.Error (LoadError (..), LoadPhase (..))
import Hinagata.Postgres.Load
import Hinagata.Postgres.Session
import Hinagata.Prelude
import Hinagata.Types
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)

main :: IO ()
main = do
  host <- lookupEnv "HINAGATA_TEST_PGHOST"
  case host of
    Nothing -> putStrLn "PostgreSQL integration tests require scripts/test-postgres.sh"
    Just socket -> integrationTests socket

integrationTests :: FilePath -> IO ()
integrationTests socket = withSystemTempDirectory "hinagata-postgres-test-" $ \workspace -> do
  portText <- requiredEnv "HINAGATA_TEST_PGPORT"
  user <- requiredEnv "HINAGATA_TEST_PGUSER"
  databaseText <- requiredEnv "HINAGATA_TEST_PGDATABASE"
  host <- orFail (socketDirectory (Text.pack socket))
  port <- orFail (mkPort (read portText))
  database <- orFail (mkDatabaseName (Text.pack databaseText))
  target <- orFail (mkConnectionTarget host port (Text.pack user) database Nothing)
  let fixtureRoot = workspace </> "fixtures"
      bundleRoot = workspace </> "bundles"
      config = BundleConfig fixtureRoot bundleRoot (positive 1048576) (positive 65536)
      goodDirectory = fixtureRoot </> "good"
      badDirectory = fixtureRoot </> "bad"
      mixedDirectory = fixtureRoot </> "mixed"
      badCopyDirectory = fixtureRoot </> "bad-copy"
      reuseDirectory = fixtureRoot </> "reuse"
      deferredDirectory = fixtureRoot </> "deferred"
      slowDirectory = fixtureRoot </> "slow"
      slowCopyDirectory = fixtureRoot </> "slow-copy"
      sequenceDirectory = fixtureRoot </> "sequence"
      analyzeDirectory = fixtureRoot </> "analyze"
      finalCopyDirectory = fixtureRoot </> "final-copy-error"
  createDirectoryIfMissing True goodDirectory
  createDirectoryIfMissing True badDirectory
  createDirectoryIfMissing True mixedDirectory
  createDirectoryIfMissing True badCopyDirectory
  createDirectoryIfMissing True reuseDirectory
  createDirectoryIfMissing True deferredDirectory
  createDirectoryIfMissing True slowDirectory
  createDirectoryIfMissing True slowCopyDirectory
  createDirectoryIfMissing True sequenceDirectory
  createDirectoryIfMissing True analyzeDirectory
  createDirectoryIfMissing True finalCopyDirectory
  ByteString.writeFile (goodDirectory </> "fixture.sql") "INSERT INTO items (id, note) VALUES (1, 'first'); INSERT INTO items (id, note) VALUES (2, 'second');"
  ByteString.writeFile (badDirectory </> "fixture.yaml") "name: bad\nsteps:\n  - sql: first.sql\n  - sql: fail.sql\n"
  ByteString.writeFile (badDirectory </> "first.sql") "INSERT INTO items (id, note) VALUES (3, 'rolled back');"
  ByteString.writeFile (badDirectory </> "fail.sql") "INSERT INTO items (id, note) VALUES (1, 'duplicate');"
  ByteString.writeFile (mixedDirectory </> "fixture.yaml") "name: mixed\nsteps:\n  - sql: before.sql\n  - copy:\n      table: {schema: public, name: items}\n      columns: [id, note]\n      file: rows.csv\n      format: csv\n      header: false\n  - sql: after.sql\n"
  ByteString.writeFile (mixedDirectory </> "before.sql") "INSERT INTO items (id, note) VALUES (4, 'before');"
  ByteString.writeFile (mixedDirectory </> "rows.csv") "5,from csv\n6,from csv\n"
  ByteString.writeFile (mixedDirectory </> "after.sql") "UPDATE items SET note = 'after' WHERE id = 6;"
  ByteString.writeFile (badCopyDirectory </> "fixture.yaml") "name: bad-copy\nsteps:\n  - sql: before.sql\n  - copy:\n      table: {schema: public, name: items}\n      columns: [id, note]\n      file: rows.csv\n      format: csv\n      header: false\n"
  ByteString.writeFile (badCopyDirectory </> "before.sql") "INSERT INTO items (id, note) VALUES (7, 'rolled back');"
  ByteString.writeFile (badCopyDirectory </> "rows.csv") "8,first row\n1,duplicate key\n"
  ByteString.writeFile (reuseDirectory </> "fixture.sql") "INSERT INTO items (id, note) VALUES (10, 'reused session');"
  ByteString.writeFile (deferredDirectory </> "fixture.sql") "INSERT INTO child_items (parent_id) VALUES (404);"
  ByteString.writeFile (slowDirectory </> "fixture.sql") "SELECT pg_sleep(1);"
  ByteString.writeFile (slowCopyDirectory </> "fixture.yaml") "name: slow-copy\nsteps:\n  - copy:\n      table: {schema: public, name: slow_copy_items}\n      columns: [id]\n      file: rows.csv\n      format: csv\n      header: false\n"
  ByteString.writeFile (slowCopyDirectory </> "rows.csv") (ByteString.pack (unlines (map show [1 .. 200 :: Int])))
  ByteString.writeFile (sequenceDirectory </> "fixture.sql") "INSERT INTO sequence_items (id, note) VALUES (500, 'explicit'); SELECT setval(pg_get_serial_sequence('public.sequence_items', 'id'), 500, true);"
  ByteString.writeFile (analyzeDirectory </> "fixture.yaml") "name: analyze\nsteps:\n  - copy:\n      table: {schema: public, name: items}\n      columns: [id, note]\n      file: rows.csv\n      format: csv\n      header: false\n  - sql: analyze.sql\n"
  ByteString.writeFile (analyzeDirectory </> "rows.csv") "11,bulk row\n12,bulk row\n"
  ByteString.writeFile (analyzeDirectory </> "analyze.sql") "ANALYZE items;"
  ByteString.writeFile (finalCopyDirectory </> "fixture.yaml") "name: final-copy-error\nsteps:\n  - copy:\n      table: {schema: public, name: final_copy_items}\n      columns: [id]\n      file: rows.csv\n      format: csv\n      header: false\n"
  ByteString.writeFile (finalCopyDirectory </> "rows.csv") "1\n2\n"
  setupConnection <- PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString target)))
  execCheck setupConnection "CREATE TABLE items (id integer PRIMARY KEY, note text NOT NULL)"
  execCheck setupConnection "INSERT INTO items (id, note) VALUES (99, 'sentinel')"
  execCheck setupConnection "CREATE TABLE parent_items (id integer PRIMARY KEY)"
  execCheck setupConnection "CREATE TABLE child_items (parent_id integer REFERENCES parent_items(id) DEFERRABLE INITIALLY DEFERRED)"
  execCheck setupConnection "CREATE TABLE slow_copy_items (id integer PRIMARY KEY)"
  execCheck setupConnection "CREATE FUNCTION slow_copy_row() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(0.01); RETURN NEW; END $$"
  execCheck setupConnection "CREATE TRIGGER slow_copy_row BEFORE INSERT ON slow_copy_items FOR EACH ROW EXECUTE FUNCTION slow_copy_row()"
  execCheck setupConnection "CREATE TABLE sequence_items (id bigserial PRIMARY KEY, note text NOT NULL)"
  execCheck setupConnection "CREATE TABLE final_copy_items (id integer PRIMARY KEY)"
  execCheck setupConnection "CREATE FUNCTION fail_final_copy() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'final COPY failure'; END $$"
  execCheck setupConnection "CREATE TRIGGER fail_final_copy AFTER INSERT ON final_copy_items FOR EACH STATEMENT EXECUTE FUNCTION fail_final_copy()"
  goodPlan <- bundleOrFail =<< compileFixtures config [fixtureName "good"]
  loaded <- loadInto target defaultSessionOptions goodPlan
  assert "SQL closure loads" (case loaded of Right report -> fixtureCount report == 1 && stepCount report == 1; Left _ -> False)
  assert "SQL rows committed" =<< ((== 3) <$> queryInt setupConnection "SELECT count(*) FROM items")
  badPlan <- bundleOrFail =<< compileFixtures config [fixtureName "bad"]
  failed <- loadInto target defaultSessionOptions badPlan
  assert "late SQL error reported with SQLSTATE" (case failed of Left LoadError {sqlState = Just "23505", targetIdentity = Just _} -> True; _ -> False)
  assert "failed closure rolled back" =<< ((== 3) <$> queryInt setupConnection "SELECT count(*) FROM items")
  assert "sentinel remains" =<< ((== 1) <$> queryInt setupConnection "SELECT count(*) FROM items WHERE id = 99 AND note = 'sentinel'")
  mixedPlan <- bundleOrFail =<< compileFixtures config [fixtureName "mixed"]
  mixedLoaded <- loadInto target defaultSessionOptions mixedPlan
  assert "mixed SQL/COPY/SQL closure loads" (case mixedLoaded of Right report -> stepCount report == 3 && bytesSent report > 0; Left _ -> False)
  assert "mixed closure committed" =<< ((== 6) <$> queryInt setupConnection "SELECT count(*) FROM items")
  assert "post-COPY SQL ordered" =<< ((== 1) <$> queryInt setupConnection "SELECT count(*) FROM items WHERE id = 6 AND note = 'after'")
  badCopyPlan <- bundleOrFail =<< compileFixtures config [fixtureName "bad-copy"]
  badCopyResult <- loadInto target defaultSessionOptions badCopyPlan
  assert "late COPY error reported" (case badCopyResult of Left _ -> True; Right _ -> False)
  assert "failed COPY rolls back prior SQL and rows" =<< ((== 6) <$> queryInt setupConnection "SELECT count(*) FROM items")
  reusePlan <- bundleOrFail =<< compileFixtures config [fixtureName "reuse"]
  reused <- withSession target defaultSessionOptions $ \session -> do
    first <- loadPlan session badPlan
    second <- loadPlan session reusePlan
    pure (first, second)
  assert "session reuses after rollback" (case reused of Right (Left _, Right _) -> True; _ -> False)
  assert "reused session committed" =<< ((== 7) <$> queryInt setupConnection "SELECT count(*) FROM items")
  deferredPlan <- bundleOrFail =<< compileFixtures config [fixtureName "deferred"]
  deferred <- loadInto target defaultSessionOptions deferredPlan
  assert "deferred constraint failure reported at COMMIT" (case deferred of Left LoadError {phase = CommitLoad} -> True; _ -> False)
  assert "deferred failure did not insert" =<< ((== 0) <$> queryInt setupConnection "SELECT count(*) FROM child_items")
  ByteString.writeFile (planDirectory mixedPlan </> "step-1") "corrupted"
  corrupt <- loadInto target defaultSessionOptions mixedPlan
  assert "modified bundle refused before mutation" (case corrupt of Left LoadError {phase = VerifyBundle} -> True; _ -> False)
  assert "modified bundle left target intact" =<< ((== 7) <$> queryInt setupConnection "SELECT count(*) FROM items")
  slowPlan <- bundleOrFail =<< compileFixtures config [fixtureName "slow"]
  concurrent <- withSession target defaultSessionOptions $ \session -> do
    finished <- newEmptyMVar
    _ <- forkIO (loadPlan session slowPlan >>= putMVar finished)
    threadDelay 100000
    simultaneous <- loadPlan session reusePlan
    first <- timeout 3000000 (takeMVar finished)
    pure (simultaneous, first)
  assert "simultaneous session use refused" (case concurrent of Right (Left LoadError {cause = "SessionBusy"}, Just (Right _)) -> True; _ -> False)
  escaped <- withSession target defaultSessionOptions pure
  afterClose <- case escaped of
    Left failure -> fail (show failure)
    Right closed -> loadPlan closed slowPlan
  assert "closed session refused" (case afterClose of Left LoadError {cause = "SessionClosed"} -> True; _ -> False)
  tcp <- orFail (tcpHost "127.0.0.1")
  tcpTarget <- orFail (mkConnectionTarget tcp port (Text.pack user) database Nothing)
  tcpEnabled <- lookupEnv "HINAGATA_TEST_TCP"
  case tcpEnabled of
    Just "1" -> do
      tcpResult <- loadInto tcpTarget defaultSessionOptions slowPlan
      assert "TCP target loads without socket fallback" (case tcpResult of Right _ -> True; Left _ -> False)
    _ -> do
      tcpAttempt <- withSession tcpTarget defaultSessionOptions (const (pure ()))
      assert "socket-only cluster does not silently retry TCP" (case tcpAttempt of Left _ -> True; Right _ -> False)
  missingHost <- orFail (socketDirectory (Text.pack (socket </> "missing")))
  missingTarget <- orFail (mkConnectionTarget missingHost port (Text.pack user) database Nothing)
  missingSocket <- withSession missingTarget defaultSessionOptions (const (pure ()))
  assert "missing socket fails without a TCP fallback" (case missingSocket of Left _ -> True; Right _ -> False)
  slowCopyPlan <- bundleOrFail =<< compileFixtures config [fixtureName "slow-copy"]
  cancelled <- withSession target defaultSessionOptions $ \session -> do
    completed <- newEmptyMVar
    worker <- forkIO (try @SomeException (loadPlan session slowCopyPlan) >>= putMVar completed)
    threadDelay 100000
    killThread worker
    interrupted <- timeout 3000000 (takeMVar completed)
    afterInterrupt <- loadPlan session slowCopyPlan
    pure (interrupted, afterInterrupt)
  assert "COPY interruption closes the session" (case cancelled of Right (Just (Left _), Left LoadError {cause = "SessionClosed"}) -> True; _ -> False)
  assert "cancelled COPY left no rows" =<< ((== 0) <$> queryInt setupConnection "SELECT count(*) FROM slow_copy_items")
  detached <- waitForNoLoader setupConnection 5000000
  assert "cancelled loader connection exits within cleanup deadline" detached
  disconnected <- withSession target defaultSessionOptions $ \session -> do
    completed <- newEmptyMVar
    _ <- forkIO (try @SomeException (loadPlan session slowPlan) >>= putMVar completed)
    threadDelay 100000
    terminated <- PQ.exec setupConnection "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()"
    assert "server disconnect request succeeded" (case terminated of Just _ -> True; Nothing -> False)
    result <- timeout 3000000 (takeMVar completed)
    retry <- loadPlan session slowPlan
    pure (result, retry)
  assert "server disconnect retires session" (case disconnected of Right (Just (Right (Left _)), Left LoadError {cause = "SessionClosed"}) -> True; Right (Just (Left _), Left LoadError {cause = "SessionClosed"}) -> True; _ -> False)
  sequencePlan <- bundleOrFail =<< compileFixtures config [fixtureName "sequence"]
  sequenced <- loadInto target defaultSessionOptions sequencePlan
  assert "explicit ID and sequence adjustment load" (case sequenced of Right _ -> True; _ -> False)
  generatedId <- queryInt setupConnection "INSERT INTO sequence_items (note) VALUES ('generated') RETURNING id"
  assert "application insert follows explicit ID" (generatedId == 501)
  analyzePlan <- bundleOrFail =<< compileFixtures config [fixtureName "analyze"]
  analyzed <- loadInto target defaultSessionOptions analyzePlan
  assert "explicit ANALYZE follows COPY and has separate stage timings" (case analyzed of Right report -> stepCount report == 2 && bytesSent report > 0 && copyMs report <= elapsedMs report && sqlMs report <= elapsedMs report; _ -> False)
  assert "ANALYZE fixture committed" =<< ((== 9) <$> queryInt setupConnection "SELECT count(*) FROM items")
  finalCopyPlan <- bundleOrFail =<< compileFixtures config [fixtureName "final-copy-error"]
  finalCopy <- loadInto target defaultSessionOptions finalCopyPlan
  assert "final COPY result error is reported" (case finalCopy of Left LoadError {phase = ExecuteCopy, sqlState = Just "P0001"} -> True; _ -> False)
  assert "final COPY result error rolls back" =<< ((== 0) <$> queryInt setupConnection "SELECT count(*) FROM final_copy_items")
  PQ.finish setupConnection

requiredEnv :: String -> IO String
requiredEnv name = maybe (fail (name ++ " is missing")) pure =<< lookupEnv name

execCheck :: PQ.Connection -> ByteString.ByteString -> IO ()
execCheck connection statement = do
  result <- PQ.exec connection statement
  case result of
    Nothing -> fail "PostgreSQL returned no result"
    Just value -> do
      status <- PQ.resultStatus value
      unless (status == PQ.CommandOk) (fail ("unexpected result: " ++ show status))

queryInt :: PQ.Connection -> ByteString.ByteString -> IO Int
queryInt connection statement = do
  result <- PQ.exec connection statement
  case result of
    Nothing -> fail "PostgreSQL returned no result"
    Just value -> do
      cell <- PQ.getvalue value (PQ.toRow (0 :: Int)) (PQ.toColumn (0 :: Int))
      maybe (fail "PostgreSQL returned null") (pure . read . ByteString.unpack) cell

fixtureName :: Text -> FixtureName
fixtureName = either (error . Text.unpack) id . mkFixtureName

positive :: Int -> Positive
positive = either (error . Text.unpack) id . mkPositive "test limit"

bundleOrFail :: Either BundleError FixturePlan -> IO FixturePlan
bundleOrFail = either (fail . show) pure

orFail :: (Show e) => Either e a -> IO a
orFail = either (fail . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition $ putStrLn ("FAIL: " ++ label) >> exitFailure

waitForNoLoader :: PQ.Connection -> Int -> IO Bool
waitForNoLoader connection remaining = do
  active <- queryInt connection "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()"
  if active == 0
    then pure True
    else
      if remaining <= 0
        then pure False
        else threadDelay 50000 >> waitForNoLoader connection (remaining - 50000)
