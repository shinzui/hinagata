module Main (main) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, try)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find, nub)
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import Hinagata.Config
import Hinagata.Connection
import Hinagata.Fixture.Bundle
import Hinagata.Fixture.Types
import Hinagata.Postgres.Baseline hiding (elapsedMs)
import Hinagata.Postgres.Cleanup
import Hinagata.Postgres.Error (LoadError (..), LoadPhase (..))
import Hinagata.Postgres.Lease
import Hinagata.Postgres.Load
import Hinagata.Postgres.Manager
import Hinagata.Postgres.Ownership
import Hinagata.Postgres.Session
import Hinagata.Prelude
import Hinagata.Types
import Paths_hinagata_postgres (getDataFileName)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.Environment (getArgs, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process (ProcessHandle, getPid, getProcessExitCode, proc, waitForProcess, withCreateProcess)
import System.Timeout (timeout)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--crash-lease-worker", fixtureRoot, bundleRoot, mode, readyFile] -> crashLeaseWorker fixtureRoot bundleRoot mode readyFile
    [] -> do
      host <- lookupEnv "HINAGATA_TEST_PGHOST"
      case host of
        Nothing -> putStrLn "PostgreSQL integration tests require scripts/test-postgres.sh"
        Just socket -> integrationTests socket
    _ -> fail "unknown integration-test arguments"

integrationTests :: FilePath -> IO ()
integrationTests socket = withSystemTempDirectory "hinagata-postgres-test-" $ \workspace -> do
  portText <- requiredEnv "HINAGATA_TEST_PGPORT"
  user <- requiredEnv "HINAGATA_TEST_PGUSER"
  databaseText <- requiredEnv "HINAGATA_TEST_PGDATABASE"
  ownedCluster <- (== Just "1") <$> lookupEnv "HINAGATA_TEST_OWNED_CLUSTER"
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
  when ownedCluster (lifecycleTests target setupConnection host port (Text.pack user) database fixtureRoot bundleRoot goodPlan)
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

lifecycleConfigFor :: Host -> Port -> Text -> DatabaseName -> FilePath -> FilePath -> SqlIdentifier -> ProjectId -> SqlIdentifier -> SqlIdentifier -> HinagataConfig
lifecycleConfigFor host port adminUser database fixtureRoot bundleRoot catalogSchema projectId publicSchema messageSetting =
  HinagataConfig
    { endpoint = EndpointConfig host port,
      project = projectId,
      fixtureRoot,
      bundleRoot,
      maintenanceDatabase = database,
      maintenanceSchema = catalogSchema,
      administration = AccessConfig adminUser database Nothing,
      setup = AccessConfig "hinagata_setup" database Nothing,
      application = AccessConfig "hinagata_app" database Nothing,
      setupGrants = [GrantConnect, GrantCreate, GrantTemporary],
      applicationGrants = [GrantConnect],
      setupSchemaGrants = [SchemaGrant publicSchema SchemaUsage, SchemaGrant publicSchema SchemaCreate],
      applicationSchemaGrants = [SchemaGrant publicSchema SchemaUsage],
      setupSettings = [RoleSetting messageSetting "warning"],
      applicationSettings = [RoleSetting messageSetting "warning"],
      cloneStrategy = WalLog,
      acquisitionDeadlineMs = positive 300000,
      setupDeadlineMs = positive 300000,
      setupWorkers = positive 2,
      activeLeases = positive 4,
      pendingRequests = positive 8,
      chunkSize = positive 65536,
      sqlSizeLimit = positive 1048576
    }

crashLeaseWorker :: FilePath -> FilePath -> String -> FilePath -> IO ()
crashLeaseWorker fixtureRoot bundleRoot mode readyFile = do
  socket <- requiredEnv "HINAGATA_TEST_PGHOST"
  portText <- requiredEnv "HINAGATA_TEST_PGPORT"
  adminUser <- Text.pack <$> requiredEnv "HINAGATA_TEST_PGUSER"
  database <- orFail . mkDatabaseName . Text.pack =<< requiredEnv "HINAGATA_TEST_PGDATABASE"
  host <- orFail (socketDirectory (Text.pack socket))
  port <- orFail (mkPort (read portText))
  catalogSchema <- orFail (mkSqlIdentifier "hinagata_test")
  projectId <- orFail (mkProjectId "baseline-test")
  publicSchema <- orFail (mkSqlIdentifier "public")
  messageSetting <- orFail (mkSqlIdentifier "client_min_messages")
  let configuration = lifecycleConfigFor host port adminUser database fixtureRoot bundleRoot catalogSchema projectId publicSchema messageSetting
      bundleConfig = BundleConfig fixtureRoot bundleRoot (positive 1048576) (positive 65536)
  base <- bundleOrFail =<< compileFixtures bundleConfig [fixtureName "good"]
  let unexpectedHook _ = pure (Left "crash worker unexpectedly rebuilt the baseline")
      specification = BaselineSpec configuration base (Just "migration-v1") (Just "verify-v1") ["plpgsql"] (Just "C") unexpectedHook unexpectedHook Nothing Nothing
  case mode of
    "building" -> do
      let blockedHook _ = writeReady readyFile "building" >> threadDelay 60000000 >> pure (Right ())
      _ <- ensureBaseline specification {migrationRevision = Just "migration-process-crash", migrationHook = blockedHook}
      fail "crash worker reached normal baseline completion"
    "intent" -> runLease specification bundleConfig
    "created" -> runLease specification bundleConfig
    "drop" -> runLease specification bundleConfig
    "handoff" -> runLease specification bundleConfig
    "loading" -> runLease specification bundleConfig
    _ -> fail "unknown crash-worker phase"
  where
    runLease specification bundleConfig = do
      (baseline, report) <- orFail =<< ensureBaseline specification
      assert "crash worker reuses the existing sealed baseline" (kind report == Reused)
      let scenarioName = if mode == "loading" then "crash-loading" else "scenario"
      scenario <- bundleOrFail =<< compileFixtures bundleConfig [fixtureName "good", fixtureName scenarioName]
      _ <- withDatabase (configuration specification) baseline scenario $ \LeaseInfo {leaseId} -> do
        when (mode == "handoff") (writeReady readyFile (Encoding.encodeUtf8 leaseId))
        if mode == "drop"
          then writeReady readyFile (Encoding.encodeUtf8 leaseId) >> waitForGo (readyFile ++ ".go")
          else threadDelay 60000000
      fail "crash worker reached normal lease completion"

    waitForGo path = do
      present <- doesFileExist path
      unless present (threadDelay 10000 >> waitForGo path)

writeReady :: FilePath -> ByteString.ByteString -> IO ()
writeReady path payload = do
  let temporary = path ++ ".tmp"
  ByteString.writeFile temporary payload
  renameFile temporary path

lifecycleTests :: ConnectionTarget -> PQ.Connection -> Host -> Port -> Text -> DatabaseName -> FilePath -> FilePath -> FixturePlan -> IO ()
lifecycleTests target connection host port adminUser database fixtureRoot bundleRoot goodPlan = do
  legacySchema <- orFail (mkSqlIdentifier "hinagata_legacy_test")
  legacyDdl <- ByteString.readFile =<< getDataFileName "sql/catalog-v1.sql"
  execCheck connection (Encoding.encodeUtf8 (Text.replace "%SCHEMA%" (quoteSqlIdentifier legacySchema) (Encoding.decodeUtf8 legacyDdl)))
  legacyVersion <- queryInt connection "SELECT format_version FROM hinagata_legacy_test.meta"
  assert "legacy fixture starts at catalog version 1" (legacyVersion == 1)
  legacyPreview <- inspectCatalog target legacySchema defaultSessionOptions
  assert "read-only inspection requests a legacy catalog upgrade" (case legacyPreview of Left CatalogError {cause} -> "version-2 upgrade" `Text.isInfixOf` cause; _ -> False)
  legacyUuid <- queryText connection "SELECT cluster_uuid::text FROM hinagata_legacy_test.meta"
  upgraded <- ensureCatalog target legacySchema defaultSessionOptions
  assert "owned version-1 catalog upgrades in place" (case upgraded of Right CatalogIdentity {formatVersion = 2, clusterUuid} -> Encoding.encodeUtf8 clusterUuid == legacyUuid; _ -> False)
  inspectedUpgrade <- inspectCatalog target legacySchema defaultSessionOptions
  assert "upgraded catalog passes read-only inspection" (inspectedUpgrade == upgraded)
  assert "upgrade installs diagnostic columns" =<< ((== 2) <$> queryInt connection "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'hinagata_legacy_test' AND table_name IN ('generations', 'allocations') AND column_name = 'last_error'")
  partialSchema <- orFail (mkSqlIdentifier "hinagata_partial_test")
  execCheck connection (Encoding.encodeUtf8 (Text.replace "%SCHEMA%" (quoteSqlIdentifier partialSchema) (Encoding.decodeUtf8 legacyDdl)))
  execCheck connection "ALTER TABLE hinagata_partial_test.allocations ADD COLUMN last_error text"
  refusedUpgrade <- ensureCatalog target partialSchema defaultSessionOptions
  assert "failed catalog upgrade is refused" (case refusedUpgrade of Left _ -> True; Right _ -> False)
  assert "failed upgrade rolls back format version" =<< ((== 1) <$> queryInt connection "SELECT format_version FROM hinagata_partial_test.meta")
  assert "failed upgrade rolls back its earlier DDL" =<< ((== 0) <$> queryInt connection "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'hinagata_partial_test' AND table_name = 'generations' AND column_name = 'last_error'")
  catalogSchema <- orFail (mkSqlIdentifier "hinagata_test")
  absentPreview <- inspectCatalog target catalogSchema defaultSessionOptions
  assert "catalog inspection refuses an absent schema without creating it" (case absentPreview of Left _ -> True; Right _ -> False)
  assert "catalog inspection leaves the schema absent" =<< ((== 0) <$> queryInt connection "SELECT count(*) FROM pg_namespace WHERE nspname = 'hinagata_test'")
  firstCatalog <- ensureCatalog target catalogSchema defaultSessionOptions
  secondCatalog <- ensureCatalog target catalogSchema defaultSessionOptions
  assert "catalog initializes and reuses one cluster identity" (case (firstCatalog, secondCatalog) of (Right first, Right second) -> first == second && formatVersion first == 2; _ -> False)
  catalog <- orFail firstCatalog
  execCheck connection "CREATE DATABASE hinagata_owned_test"
  let marker = "hinagata:v1:" <> clusterUuid catalog <> ":test-token"
  execCheck connection (Encoding.encodeUtf8 ("COMMENT ON DATABASE hinagata_owned_test IS '" <> marker <> "'"))
  ownedName <- orFail (mkDatabaseName "hinagata_owned_test")
  ownedOid <- queryInt connection "SELECT oid FROM pg_database WHERE datname = 'hinagata_owned_test'"
  let owned = OwnedDatabase {name = ownedName, oid = ownedOid, token = "test-token"}
  matched <- verifyOwnedDatabase target defaultSessionOptions catalog owned
  assert "name, OID, and marker prove ownership" (matched == Right OwnershipMatches)
  execCheck connection "COMMENT ON DATABASE hinagata_owned_test IS 'foreign'"
  replaced <- verifyOwnedDatabase target defaultSessionOptions catalog owned
  assert "changed ownership marker is refused" (replaced == Right OwnershipMismatch)
  execCheck connection "DROP DATABASE hinagata_owned_test"
  missing <- verifyOwnedDatabase target defaultSessionOptions catalog owned
  assert "missing owned database is distinct from a mismatch" (missing == Right OwnershipMissing)
  execCheck connection "CREATE SCHEMA foreign_catalog"
  foreignSchema <- orFail (mkSqlIdentifier "foreign_catalog")
  foreignCatalog <- ensureCatalog target foreignSchema defaultSessionOptions
  assert "existing foreign schema without format marker is refused" (case foreignCatalog of Left _ -> True; _ -> False)

  execCheck connection "CREATE ROLE hinagata_setup LOGIN"
  execCheck connection "CREATE ROLE hinagata_app LOGIN"
  projectId <- orFail (mkProjectId "baseline-test")
  publicSchema <- orFail (mkSqlIdentifier "public")
  messageSetting <- orFail (mkSqlIdentifier "client_min_messages")
  migrationCalls <- newIORef (0 :: Int)
  let lifecycleConfig = lifecycleConfigFor host port adminUser database fixtureRoot bundleRoot catalogSchema projectId publicSchema messageSetting
      adminRole = AccessConfig adminUser database Nothing
      setupRole = AccessConfig "hinagata_setup" database Nothing
      appRole = AccessConfig "hinagata_app" database Nothing
      migrate setupTarget = do
        modifyIORef' migrationCalls (+ 1)
        migrated <- PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString setupTarget)))
        level <- queryText migrated "SHOW client_min_messages"
        assert "setup role settings apply before migration" (level == "warning")
        execCheck migrated "CREATE TABLE items (id integer PRIMARY KEY, note text NOT NULL)"
        execCheck migrated "GRANT SELECT, INSERT ON items TO hinagata_app"
        execCheck migrated "CREATE INDEX CONCURRENTLY items_note_idx ON items (note)"
        PQ.finish migrated
        pure (Right ())
      verify setupTarget = do
        verified <- PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString setupTarget)))
        count <- queryInt verified "SELECT count(*) FROM items"
        PQ.finish verified
        pure (if count == 2 then Right () else Left "unexpected baseline rows")
      baselineSpec = BaselineSpec lifecycleConfig goodPlan (Just "migration-v1") (Just "verify-v1") ["plpgsql"] (Just "C") migrate verify Nothing Nothing
  firstBaseline <- ensureBaseline baselineSpec
  secondBaseline <- ensureBaseline baselineSpec
  (firstRef, firstReport) <- orFail firstBaseline
  (secondRef, secondReport) <- orFail secondBaseline
  calls <- readIORef migrationCalls
  assert "baseline builds once and reuses a sealed generation" (baselineDatabase firstRef == baselineDatabase secondRef && kind firstReport == Built && kind secondReport == Reused && comparison firstReport == Nothing && comparison secondReport == Nothing && calls == 1)
  recordedManifest <- queryText connection "SELECT fingerprint_manifest::text FROM hinagata_test.generations WHERE state = 'Ready' LIMIT 1"
  assert "fingerprint manifest omits raw role-setting values" (not ("warning" `ByteString.isInfixOf` recordedManifest))
  rotatedPassword <- orFail (mkSecret "rotated-passphrase")
  let rotatedConfig = lifecycleConfig {administration = adminRole {password = Just rotatedPassword}, setup = setupRole {password = Just rotatedPassword}, application = appRole {password = Just rotatedPassword}}
  rotated <- ensureBaseline baselineSpec {configuration = rotatedConfig, compareAgainst = Just firstRef}
  assert "credential rotation does not invalidate a baseline" (case rotated of Right (ref, report) -> baselineDatabase ref == baselineDatabase firstRef && kind report == Reused && fmap changedComponents (comparison report) == Just []; _ -> False)
  let sealedSql = Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> databaseNameText (baselineDatabase firstRef) <> "' AND datallowconn = false")
  assert "ready baseline rejects connections" =<< ((== 1) <$> queryInt connection sealedSql)
  createDirectoryIfMissing True (fixtureRoot </> "scenario")
  ByteString.writeFile (fixtureRoot </> "scenario" </> "fixture.sql") "INSERT INTO items (id, note) VALUES (3, 'scenario');"
  scenarioPlan <- bundleOrFail =<< compileFixtures (BundleConfig fixtureRoot bundleRoot (positive 1048576) (positive 65536)) [fixtureName "good", fixtureName "scenario"]
  let consume info = do
        app <- PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString (applicationTarget info))))
        count <- queryInt app "SELECT count(*) FROM items"
        assert "clone contains one base prefix plus scenario suffix" (count == 3)
        execCheck app "INSERT INTO items (id, note) VALUES (4, 'application')"
        PQ.finish app
        pure (connectionDatabase (applicationTarget info))
  firstLease <- withDatabase lifecycleConfig firstRef scenarioPlan consume
  secondLease <- withDatabase lifecycleConfig firstRef scenarioPlan consume
  firstClone <- orFail firstLease
  secondClone <- orFail secondLease
  assert "bracketed clones are distinct" (firstClone /= secondClone)
  assert "released clone databases are dropped" =<< ((== 0) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname IN ('" <> databaseNameText firstClone <> "', '" <> databaseNameText secondClone <> "')")))
  assert "clone release records terminal state" =<< ((== 2) <$> queryInt connection "SELECT count(*) FROM hinagata_test.leases WHERE state = 'Released'")
  firstStarted <- newEmptyMVar
  secondStarted <- newEmptyMVar
  releaseCallbacks <- newEmptyMVar
  firstDone <- newEmptyMVar
  secondDone <- newEmptyMVar
  _ <- forkIO (try @SomeException (withDatabase lifecycleConfig firstRef scenarioPlan (\info -> consume info >>= \clone -> putMVar firstStarted clone >> takeMVar releaseCallbacks >> pure clone)) >>= putMVar firstDone)
  _ <- forkIO (try @SomeException (withDatabase lifecycleConfig firstRef scenarioPlan (\info -> consume info >>= \clone -> putMVar secondStarted clone >> takeMVar releaseCallbacks >> pure clone)) >>= putMVar secondDone)
  warmFirst <- timeout 10000000 (takeMVar firstStarted)
  warmSecond <- timeout 10000000 (takeMVar secondStarted)
  assert "concurrent warm callers hold distinct writable clones" (case (warmFirst, warmSecond) of (Just left, Just right) -> left /= right; _ -> False)
  putMVar releaseCallbacks ()
  putMVar releaseCallbacks ()
  warmFirstDone <- timeout 10000000 (takeMVar firstDone)
  warmSecondDone <- timeout 10000000 (takeMVar secondDone)
  assert "concurrent callbacks release both clones" (case (warmFirstDone, warmSecondDone) of (Just (Right (Right _)), Just (Right (Right _))) -> True; _ -> False)
  thrown <- try @SomeException (withDatabase lifecycleConfig firstRef scenarioPlan (\_ -> fail "intentional callback failure"))
  assert "callback exception propagates after cleanup" (case thrown of Left _ -> True; Right _ -> False)
  assert "exceptional callback released its clone" =<< ((== 5) <$> queryInt connection "SELECT count(*) FROM hinagata_test.leases WHERE state = 'Released'")
  badScenario <- bundleOrFail =<< compileFixtures (BundleConfig fixtureRoot bundleRoot (positive 1048576) (positive 65536)) [fixtureName "bad"]
  failedLoad <- withDatabase lifecycleConfig firstRef badScenario (\_ -> pure ())
  assert "failed scenario load refuses callback" (case failedLoad of Left _ -> True; Right _ -> False)
  assert "failed scenario load releases its clone" =<< ((== 6) <$> queryInt connection "SELECT count(*) FROM hinagata_test.leases WHERE state = 'Released'")
  createDirectoryIfMissing True (fixtureRoot </> "slow-acquisition")
  ByteString.writeFile (fixtureRoot </> "slow-acquisition" </> "fixture.sql") "SELECT pg_sleep(2);"
  slowScenario <- bundleOrFail =<< compileFixtures (BundleConfig fixtureRoot bundleRoot (positive 1048576) (positive 65536)) [fixtureName "good", fixtureName "slow-acquisition"]
  callbackStarted <- newIORef False
  releasedBeforeTimeout <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations WHERE state = 'Released'"
  timedSetup <- withDatabase (lifecycleConfig {acquisitionDeadlineMs = positive 1500}) firstRef slowScenario (\_ -> modifyIORef' callbackStarted (const True))
  releasedAfterTimeout <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations WHERE state = 'Released'"
  ranTimedCallback <- readIORef callbackStarted
  assert "one deadline stops slow scenario setup before callback and releases its clone" (case timedSetup of Left LeaseError {cause = "acquisition deadline expired"} -> not ranTimedCallback && releasedAfterTimeout == releasedBeforeTimeout + 1; _ -> False)
  slowConsumer <- withDatabase (lifecycleConfig {acquisitionDeadlineMs = positive 1500}) firstRef scenarioPlan (\_ -> threadDelay 1700000 >> pure True)
  assert "acquisition deadline stops at callback handoff" (slowConsumer == Right True)
  timedLease <- withDatabaseClassified lifecycleConfig firstRef slowScenario ReleaseAlways (const False) (\_ -> pure (42 :: Int))
  assert "lease timing separates scenario load from clone and release" (case timedLease of Right LeaseOutcome {callbackValue = 42, timings = LeaseTimings {queueWaitMs = 0, cloneMs, scenarioLoadMs, completionMs}} -> cloneMs > 0 && scenarioLoadMs >= 1500 && completionMs > 0; _ -> False)
  cloneHookCalls <- newIORef (0 :: Int)
  let prepareCloneHook setupTarget = do
        modifyIORef' cloneHookCalls (+ 1)
        prepared <- PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString setupTarget)))
        execCheck prepared "CREATE TABLE clone_hook_probe (value integer NOT NULL)"
        execCheck prepared "INSERT INTO clone_hook_probe (value) VALUES (42)"
        execCheck prepared "GRANT SELECT ON clone_hook_probe TO hinagata_app"
        PQ.finish prepared
        pure (Right ())
  hookedBaseline <- ensureBaseline baselineSpec {clonePreparationHook = Just prepareCloneHook}
  (hookedRef, hookedReport) <- orFail hookedBaseline
  assert "adding clone preparation does not rebuild an unchanged template" (kind hookedReport == Reused && baselineDatabase hookedRef == baselineDatabase firstRef)
  let inspectHook info = do
        app <- PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString (applicationTarget info))))
        value <- queryInt app "SELECT value FROM clone_hook_probe"
        PQ.finish app
        pure value
  firstHooked <- withDatabase lifecycleConfig hookedRef scenarioPlan inspectHook
  secondHooked <- withDatabase lifecycleConfig hookedRef scenarioPlan inspectHook
  hookCalls <- readIORef cloneHookCalls
  assert "clone preparation runs separately before both callback handoffs" (firstHooked == Right 42 && secondHooked == Right 42 && hookCalls == 2)
  failedHookBaseline <- ensureBaseline baselineSpec {clonePreparationHook = Just (\_ -> pure (Left "intentional hook failure"))}
  (failedHookRef, _) <- orFail failedHookBaseline
  failedHookCallback <- newIORef False
  failedHookLease <- withDatabase lifecycleConfig failedHookRef scenarioPlan (\_ -> modifyIORef' failedHookCallback (const True))
  calledAfterFailedHook <- readIORef failedHookCallback
  assert "failed clone preparation releases its clone before callback" (case failedHookLease of Left LeaseError {cause = "clone preparation hook failed"} -> not calledAfterFailedHook; _ -> False)
  withManager lifecycleConfig $ \manager -> do
    let requests = DatabaseRequest "zeta" firstRef scenarioPlan :| [DatabaseRequest "alpha" firstRef scenarioPlan]
    collection <-
      withDatabases
        manager
        requests
        ( \entries -> do
            assert "named collection orders acquisitions stably" (map fst entries == ["alpha", "zeta"])
            traverse (consume . snd) entries
        )
    clones <- orFail collection
    assert "named collection has simultaneous distinct clones" (case clones of [left, right] -> left /= right; _ -> False)
    beforePartial <- queryInt connection "SELECT count(*) FROM hinagata_test.leases WHERE state = 'Released'"
    partial <- withDatabases manager (DatabaseRequest "alpha" firstRef scenarioPlan :| [DatabaseRequest "zeta" firstRef badScenario]) (\_ -> pure ())
    afterPartial <- queryInt connection "SELECT count(*) FROM hinagata_test.leases WHERE state = 'Released'"
    assert "later collection failure unwinds earlier clones" (case partial of Left _ -> afterPartial == beforePartial + 2; Right _ -> False)
    managedFailure <- withManagedDatabaseClassified manager firstRef scenarioPlan PreserveFailures not (\_ -> pure False)
    managedInfo <- case managedFailure of
      Right LeaseOutcome {callbackValue = False, leaseDisposition = LeasePreserved, leaseInfo} -> pure leaseInfo
      _ -> fail "managed classified failure was not retained"
    let LeaseInfo {leaseId = managedId} = managedInfo
    managedRelease <- releaseLease lifecycleConfig managedId
    assert "managed preserved lease releases by ID" (case managedRelease of Right (Released _) -> True; _ -> False)
    managedDetached <- orFail =<< acquireManagedDetached manager firstRef scenarioPlan
    let LeaseInfo {leaseId = managedDetachedId} = managedDetached
    managedDetachedRelease <- releaseLease lifecycleConfig managedDetachedId
    assert "manager capacity is released after detached acquisition" (case managedDetachedRelease of Right (Released _) -> True; _ -> False)
  let tightConfig = lifecycleConfig {activeLeases = positive 1, pendingRequests = positive 1, setupWorkers = positive 1}
  withManager tightConfig $ \manager -> do
    allocationsBeforeOversize <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations"
    oversize <- withDatabases manager (DatabaseRequest "a" firstRef scenarioPlan :| [DatabaseRequest "b" firstRef scenarioPlan]) (\_ -> pure ())
    allocationsAfterOversize <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations"
    assert "oversized collection is refused before allocation" (case oversize of Left _ -> allocationsBeforeOversize == allocationsAfterOversize; Right _ -> False)
    held <- newEmptyMVar
    releaseHeld <- newEmptyMVar
    firstFinished <- newEmptyMVar
    secondFinished <- newEmptyMVar
    thirdFinished <- newEmptyMVar
    _ <- forkIO (try @SomeException (withManagedDatabase manager firstRef scenarioPlan (\_ -> putMVar held () >> takeMVar releaseHeld)) >>= putMVar firstFinished)
    _ <- takeMVar held
    queuedWorker <- forkIO (try @SomeException (withManagedDatabase manager firstRef scenarioPlan (\_ -> pure ())) >>= putMVar secondFinished)
    threadDelay 100000
    saturated <- withManagedDatabase manager firstRef scenarioPlan (\_ -> pure ())
    assert "manager rejects a full pending queue before allocation" (case saturated of Left _ -> True; Right _ -> False)
    killThread queuedWorker
    cancelledQueue <- timeout 1000000 (takeMVar secondFinished)
    assert "queued admission can be cancelled" (case cancelledQueue of Just (Left _) -> True; _ -> False)
    _ <- forkIO (try @SomeException (withManagedDatabase manager firstRef scenarioPlan (\_ -> pure ())) >>= putMVar thirdFinished)
    putMVar releaseHeld ()
    firstResult <- timeout 10000000 (takeMVar firstFinished)
    thirdResult <- timeout 10000000 (takeMVar thirdFinished)
    assert "manager releases capacity after callback and queue cancellation" (case (firstResult, thirdResult) of (Just (Right (Right _)), Just (Right (Right _))) -> True; _ -> False)
    timingHeld <- newEmptyMVar
    timingRelease <- newEmptyMVar
    timingHolderDone <- newEmptyMVar
    timingWaiterDone <- newEmptyMVar
    _ <- forkIO (withManagedDatabase manager firstRef scenarioPlan (\_ -> putMVar timingHeld () >> takeMVar timingRelease) >>= putMVar timingHolderDone)
    _ <- takeMVar timingHeld
    _ <- forkIO (withManagedDatabaseClassified manager firstRef scenarioPlan ReleaseAlways (const False) (\_ -> pure ()) >>= putMVar timingWaiterDone)
    threadDelay 200000
    putMVar timingRelease ()
    timingHolder <- timeout 10000000 (takeMVar timingHolderDone)
    timingWaiter <- timeout 10000000 (takeMVar timingWaiterDone)
    assert "managed timing records active-queue wait" (case (timingHolder, timingWaiter) of (Just (Right ()), Just (Right LeaseOutcome {timings = LeaseTimings {queueWaitMs}})) -> queueWaitMs >= 150; _ -> False)
  let deadlineConfig = tightConfig {acquisitionDeadlineMs = positive 1000}
  withManager deadlineConfig $ \manager -> do
    held <- newEmptyMVar
    releaseHeld <- newEmptyMVar
    finished <- newEmptyMVar
    _ <- forkIO (try @SomeException (withManagedDatabase manager firstRef scenarioPlan (\_ -> putMVar held () >> takeMVar releaseHeld)) >>= putMVar finished)
    _ <- takeMVar held
    expired <- withManagedDatabase manager firstRef scenarioPlan (\_ -> pure ())
    assert "queued acquisition obeys its deadline" (case expired of Left _ -> True; Right _ -> False)
    putMVar releaseHeld ()
    holder <- timeout 10000000 (takeMVar finished)
    assert "deadline does not cancel another caller's lease" (case holder of Just (Right (Right _)) -> True; _ -> False)
    afterDeadline <- withManagedDatabase manager firstRef scenarioPlan (\_ -> pure ())
    assert "deadline releases pending admission" (case afterDeadline of Right _ -> True; Left _ -> False)
  connectionCeilingTest lifecycleConfig firstRef scenarioPlan connection
  eightWarmTest lifecycleConfig firstRef scenarioPlan connection
  processCrashTests lifecycleConfig baselineSpec connection fixtureRoot bundleRoot
  cleanupLifecycleTests lifecycleConfig catalog firstRef scenarioPlan connection database
  retentionLifecycleTests lifecycleConfig firstRef scenarioPlan connection catalog
  generationLifecycleTests lifecycleConfig baselineSpec firstRef scenarioPlan fixtureRoot bundleRoot connection migrationCalls messageSetting target catalogSchema

connectionCeilingTest :: HinagataConfig -> BaselineRef -> FixturePlan -> PQ.Connection -> IO ()
connectionCeilingTest configuration baseline scenario connection = withManager configuration $ \manager -> do
  ready <- mapM (const newEmptyMVar) [1 .. 4 :: Int]
  finished <- mapM (const newEmptyMVar) [1 .. 4 :: Int]
  release <- newEmptyMVar
  let holdApplication info signal =
        bracket
          (PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString (applicationTarget info)))))
          PQ.finish
          (\app -> queryInt app "SELECT count(*) FROM items" >> putMVar signal () >> takeMVar release)
  mapM_
    (\(signal, done) -> forkIO (try @SomeException (withManagedDatabase manager baseline scenario (\info -> holdApplication info signal)) >>= putMVar done))
    (zip ready finished)
  arrivals <- mapM (timeout 10000000 . takeMVar) ready
  assert "four managed callbacks reach their application sessions" (all (== Just ()) arrivals)
  observed <- queryInt connection "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND usename IN (current_user, 'hinagata_app')"
  assert "four active leases plus one application session each stay within nine client connections including the observer" (observed == 9)
  mapM_ (const (putMVar release ())) [1 .. 4 :: Int]
  outcomes <- mapM (timeout 10000000 . takeMVar) finished
  assert "measured callbacks all release their managed leases" (all (\case Just (Right (Right ())) -> True; _ -> False) outcomes)

eightWarmTest :: HinagataConfig -> BaselineRef -> FixturePlan -> PQ.Connection -> IO ()
eightWarmTest configuration baseline scenario connection = do
  let templateName = databaseNameText (baselineDatabase baseline)
  generation <- queryText connection (Encoding.encodeUtf8 ("SELECT id FROM hinagata_test.generations WHERE database_name = '" <> templateName <> "'"))
  let key = "generation:" <> generation
      hold = queryInt connection ("SELECT 1 FROM (SELECT pg_advisory_lock_shared(1212761905, hashtext('" <> key <> "'))) held")
      unlock = queryText connection ("SELECT pg_advisory_unlock_shared(1212761905, hashtext('" <> key <> "'))::text")
  bracket hold (const unlock) $ \_ -> do
    ready <- mapM (const newEmptyMVar) [1 .. 8 :: Int]
    finished <- mapM (const newEmptyMVar) [1 .. 8 :: Int]
    release <- newEmptyMVar
    let consume number signal info =
          bracket
            (PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString (applicationTarget info)))))
            PQ.finish
            ( \app -> do
                before <- queryInt app "SELECT count(*) FROM items"
                assert "each warm clone starts with one base and scenario closure" (before == 3)
                execCheck app (ByteString.pack ("INSERT INTO items (id, note) VALUES (" ++ show (1000 + number) ++ ", 'private')"))
                after <- queryInt app "SELECT count(*) FROM items"
                assert "each warm clone accepts an isolated application write" (after == 4)
                putMVar signal (connectionDatabase (applicationTarget info))
                takeMVar release
            )
    mapM_
      (\(number, signal, done) -> forkIO (try @SomeException (withDatabase configuration baseline scenario (consume number signal)) >>= putMVar done))
      (zip3 [1 .. 8 :: Int] ready finished)
    arrivals <- mapM (timeout 20000000 . takeMVar) ready
    assert "eight warm callbacks acquire while a shared generation lock is held" (all isJust arrivals)
    let names = catMaybes arrivals
    assert "eight warm callbacks hold distinct writable databases" (length (nub names) == 8)
    mapM_ (const (putMVar release ())) [1 .. 8 :: Int]
    outcomes <- mapM (timeout 20000000 . takeMVar) finished
    assert "all eight warm callbacks release cleanly" (all (\case Just (Right (Right ())) -> True; _ -> False) outcomes)

processCrashTests :: HinagataConfig -> BaselineSpec -> PQ.Connection -> FilePath -> FilePath -> IO ()
processCrashTests configuration baselineSpec connection fixtureRoot bundleRoot = do
  let slowDirectory = fixtureRoot </> "crash-loading"
  createDirectoryIfMissing True slowDirectory
  ByteString.writeFile (slowDirectory </> "fixture.sql") "SELECT pg_sleep(30);"
  executable <- getExecutablePath
  runBuilderCase executable
  runUnboundCase executable "intent" "LOCK TABLE pg_database IN SHARE ROW EXCLUSIVE MODE" "CREATE DATABASE %" False
  runUnboundCase executable "created" "LOCK TABLE pg_shdescription IN SHARE ROW EXCLUSIVE MODE" "COMMENT ON DATABASE %" True
  runDropCase executable
  mapM_ (runCase executable) ["loading", "handoff"]
  where
    runDropCase executable = do
      let readyFile = bundleRoot </> "crash-drop.ready"
          command = proc executable ["--crash-lease-worker", fixtureRoot, bundleRoot, "drop", readyFile]
      withCreateProcess command $ \_ _ _ child -> do
        lease <- waitForChild child $ do
          present <- doesFileExist readyFile
          if present then Just . Encoding.decodeUtf8 <$> ByteString.readFile readyFile else pure Nothing
        allocation <- Encoding.decodeUtf8 <$> queryText connection (Encoding.encodeUtf8 ("SELECT allocation_id FROM hinagata_test.leases WHERE id = '" <> lease <> "'"))
        database <- Encoding.decodeUtf8 <$> queryText connection (Encoding.encodeUtf8 ("SELECT database_name::text FROM hinagata_test.allocations WHERE id = '" <> allocation <> "'"))
        let leaseKey = "lease:" <> lease
        serverPid <- queryInt connection (Encoding.encodeUtf8 ("SELECT pid FROM pg_locks WHERE locktype = 'advisory' AND classid = 1212761905::oid AND objid = hashtext('" <> leaseKey <> "')::oid AND granted AND pid <> pg_backend_pid()"))
        let triggerName = "pause_drop_release"
            activeSql = ByteString.pack ("SELECT count(*) FROM pg_stat_activity WHERE pid = " ++ show serverPid ++ " AND state = 'active'")
        _ <-
          bracket
            ( do
                execCheck connection "CREATE FUNCTION hinagata_test.pause_drop_release() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(30); RETURN NEW; END $$"
                execCheck connection (Encoding.encodeUtf8 ("CREATE TRIGGER " <> triggerName <> " BEFORE UPDATE ON hinagata_test.allocations FOR EACH ROW WHEN (NEW.id = '" <> allocation <> "' AND NEW.state = 'Released') EXECUTE FUNCTION hinagata_test.pause_drop_release()"))
            )
            ( \_ -> do
                execCheck connection (Encoding.encodeUtf8 ("DROP TRIGGER " <> triggerName <> " ON hinagata_test.allocations"))
                execCheck connection "DROP FUNCTION hinagata_test.pause_drop_release()"
            )
            ( \_ -> do
                writeReady (readyFile ++ ".go") "go"
                observed <- try @SomeException $ waitForChild child $ do
                  state <- queryText connection (Encoding.encodeUtf8 ("SELECT state FROM hinagata_test.allocations WHERE id = '" <> allocation <> "'"))
                  present <- queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> database <> "'"))
                  active <- queryInt connection activeSql
                  if state == "Releasing" && present == 0 && active > 0
                    then pure (Just ())
                    else pure Nothing
                case observed of
                  Right () -> pure ()
                  Left exception -> do
                    state <- queryText connection (Encoding.encodeUtf8 ("SELECT state FROM hinagata_test.allocations WHERE id = '" <> allocation <> "'"))
                    present <- queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> database <> "'"))
                    active <- queryInt connection activeSql
                    fail ("drop boundary was not reached: " ++ show exception ++ "; state=" ++ show state ++ "; present=" ++ show present ++ "; matching-backends=" ++ show active)
                processId <- maybe (fail "drop worker has no process ID") pure =<< getPid child
                signalProcess sigKILL processId
                ended <- timeout 10000000 (waitForProcess child)
                assert "killed drop worker exits abnormally" (case ended of Just ExitSuccess -> False; Just (ExitFailure _) -> True; Nothing -> False)
                activeBackend <- queryInt connection (ByteString.pack ("SELECT count(*) FROM pg_stat_activity WHERE pid = " ++ show serverPid))
                when (activeBackend > 0) (void (queryText connection (ByteString.pack ("SELECT pg_terminate_backend(" ++ show serverPid ++ ")::text"))))
                waitForBackendGone "drop" serverPid
            )
        assert "killed drop worker leaves its database absent" =<< ((== 0) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> database <> "'")))
        candidates <- orFail =<< planCleanup configuration
        candidate <- maybe (fail "killed drop allocation is absent from cleanup preview") pure (find (\item -> allocationId item == allocation) candidates)
        assert "killed drop worker leaves a Releasing allocation with a missing clone" (state candidate == "Releasing" && disposition candidate == Missing)
        released <- applyCleanup configuration OrphansOnly [allocation]
        assert "explicit cleanup idempotently records the interrupted drop" (released == Right [Released allocation])

    runUnboundCase executable mode catalogLock activePattern expectDatabase = do
      before <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations"
      let command = proc executable ["--crash-lease-worker", fixtureRoot, bundleRoot, mode, bundleRoot </> ("crash-" ++ mode ++ ".ready")]
          activeSql prefix = "SELECT " <> prefix <> " FROM pg_stat_activity WHERE state = 'active' AND query LIKE '" <> activePattern <> "' AND pid <> pg_backend_pid()"
      (identifier, serverPid) <-
        bracket
          (execCheck connection "BEGIN" >> execCheck connection catalogLock)
          (const (execCheck connection "ROLLBACK"))
          ( \_ -> withCreateProcess command $ \_ _ _ child -> do
              (identifier, serverPid) <- waitForChild child $ do
                count <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations"
                if count <= before
                  then pure Nothing
                  else do
                    latest <- queryText connection "SELECT id FROM hinagata_test.allocations ORDER BY created_at DESC LIMIT 1"
                    state <- queryText connection ("SELECT state FROM hinagata_test.allocations WHERE id = '" <> latest <> "'")
                    pending <- queryInt connection (activeSql "count(*)")
                    if state == "Allocating" && pending > 0
                      then do
                        backend <- queryInt connection (activeSql "pid" <> " LIMIT 1")
                        pure (Just (Encoding.decodeUtf8 latest, backend))
                      else pure Nothing
              processId <- maybe (fail "unbound worker has no process ID") pure =<< getPid child
              signalProcess sigKILL processId
              ended <- timeout 10000000 (waitForProcess child)
              assert ("killed " ++ mode ++ " worker exits abnormally") (case ended of Just ExitSuccess -> False; Just (ExitFailure _) -> True; Nothing -> False)
              pure (identifier, serverPid)
          )
      waitForBackendGone mode serverPid
      candidates <- orFail =<< planCleanup configuration
      candidate <- maybe (fail "unbound allocation is absent from cleanup preview") pure (find (\item -> allocationId item == identifier) candidates)
      assert ("unbound " ++ mode ++ " allocation remains ambiguous after process death") (state candidate == "Allocating" && disposition candidate == Ambiguous)
      let CleanupCandidate {database = intendedDatabase} = candidate
          existenceSql = Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> databaseNameText intendedDatabase <> "'")
      beforeApply <- queryInt connection existenceSql
      when expectDatabase (assert "database creation completed before marker binding" (beforeApply == 1))
      applied <- applyCleanup configuration OrphansOnly [identifier]
      afterApply <- queryInt connection existenceSql
      assert ("ambiguous " ++ mode ++ " allocation refuses deletion") (applied == Right [Refused identifier "allocation has no bound database OID"] && afterApply == beforeApply)

    waitForBackendGone mode serverPid = loop (100 :: Int)
      where
        statement = ByteString.pack ("SELECT count(*) FROM pg_stat_activity WHERE pid = " ++ show serverPid)
        loop 0 = fail ("server backend continued after killed " ++ mode ++ " worker")
        loop remaining = do
          active <- queryInt connection statement
          if active == 0 then pure () else threadDelay 100000 >> loop (remaining - 1)

    runBuilderCase executable = do
      let readyFile = bundleRoot </> "crash-building.ready"
          command = proc executable ["--crash-lease-worker", fixtureRoot, bundleRoot, "building", readyFile]
      withCreateProcess command $ \_ _ _ child -> do
        _ <- waitForChild child $ do
          exists <- doesFileExist readyFile
          if not exists
            then pure Nothing
            else do
              bytes <- ByteString.readFile readyFile
              pure (if bytes == "building" then Just () else Nothing)
        building <- queryInt connection "SELECT count(*) FROM hinagata_test.generations WHERE fingerprint_manifest->>'manifest' LIKE '%migration-process-crash%' AND state = 'Building'"
        assert "process-kill builder reached a recorded Building generation" (building == 1)
        processId <- maybe (fail "crash builder has no process ID") pure =<< getPid child
        signalProcess sigKILL processId
        ended <- timeout 10000000 (waitForProcess child)
        assert "killed baseline builder exits abnormally" (case ended of Just ExitSuccess -> False; Just (ExitFailure _) -> True; Nothing -> False)
      rebuilt <- ensureBaseline baselineSpec {migrationRevision = Just "migration-process-crash"}
      assert "surviving caller publishes after builder process death" (case rebuilt of Right (_, report) -> kind report == Built; Left _ -> False)
      failed <- queryInt connection "SELECT count(*) FROM hinagata_test.generations WHERE fingerprint_manifest->>'manifest' LIKE '%migration-process-crash%' AND state = 'Failed'"
      ready <- queryInt connection "SELECT count(*) FROM hinagata_test.generations WHERE fingerprint_manifest->>'manifest' LIKE '%migration-process-crash%' AND state = 'Ready'"
      assert "builder process death leaves one Failed and one Ready generation" (failed == 1 && ready == 1)

    runCase executable mode = do
      before <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations"
      let readyFile = bundleRoot </> ("crash-" ++ mode ++ ".ready")
          command = proc executable ["--crash-lease-worker", fixtureRoot, bundleRoot, mode, readyFile]
      withCreateProcess command $ \_ _ _ child -> do
        identifier <- waitForChild child $ case mode of
          "loading" -> do
            count <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations"
            if count <= before
              then pure Nothing
              else do
                latest <- queryText connection "SELECT id FROM hinagata_test.allocations ORDER BY created_at DESC LIMIT 1"
                state <- queryText connection ("SELECT state FROM hinagata_test.allocations WHERE id = '" <> latest <> "'")
                pure (if state == "Loading" then Just (Encoding.decodeUtf8 latest) else Nothing)
          "handoff" -> do
            exists <- doesFileExist readyFile
            if not exists
              then pure Nothing
              else do
                lease <- ByteString.readFile readyFile
                if ByteString.null lease
                  then pure Nothing
                  else Just . Encoding.decodeUtf8 <$> queryText connection ("SELECT allocation_id FROM hinagata_test.leases WHERE id = '" <> lease <> "'")
          _ -> fail "unknown crash phase"
        processId <- maybe (fail "crash worker has no process ID") pure =<< getPid child
        signalProcess sigKILL processId
        ended <- timeout 10000000 (waitForProcess child)
        assert ("killed " ++ mode ++ " worker exits abnormally") (case ended of Just ExitSuccess -> False; Just (ExitFailure _) -> True; Nothing -> False)
        candidate <- waitForOrphan identifier
        assert ("killed " ++ mode ++ " worker leaves an inspectable orphan") (state candidate == if mode == "loading" then "Loading" else "Active")
        released <- applyCleanup configuration OrphansOnly [identifier]
        assert ("explicit apply releases killed " ++ mode ++ " worker's clone") (released == Right [Released identifier])
        let CleanupCandidate {database = crashedDatabase} = candidate
        assert ("killed " ++ mode ++ " worker's database is absent after apply") =<< ((== 0) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> databaseNameText crashedDatabase <> "'")))

    waitForOrphan identifier = loop (100 :: Int)
      where
        loop 0 = fail "killed worker's allocation did not become orphaned"
        loop remaining = do
          candidates <- orFail =<< planCleanup configuration
          case find (\candidate -> allocationId candidate == identifier && disposition candidate == Orphaned) candidates of
            Just candidate -> pure candidate
            Nothing -> threadDelay 100000 >> loop (remaining - 1)

waitForChild :: ProcessHandle -> IO (Maybe a) -> IO a
waitForChild child probe = loop (100 :: Int)
  where
    loop 0 = fail "crash worker did not reach its requested boundary"
    loop remaining = do
      found <- probe
      case found of
        Just value -> pure value
        Nothing -> do
          exited <- getProcessExitCode child
          case exited of
            Just status -> fail ("crash worker exited before its boundary: " ++ show status)
            Nothing -> threadDelay 100000 >> loop (remaining - 1)

cleanupLifecycleTests :: HinagataConfig -> CatalogIdentity -> BaselineRef -> FixturePlan -> PQ.Connection -> DatabaseName -> IO ()
cleanupLifecycleTests lifecycleConfig catalog firstRef scenarioPlan connection database = do
  generationBytes <- queryText connection (Encoding.encodeUtf8 ("SELECT id FROM hinagata_test.generations WHERE database_name = '" <> databaseNameText (baselineDatabase firstRef) <> "'"))
  let generationText = Encoding.decodeUtf8 generationBytes
      orphanId = "11111111-1111-4111-8111-111111111111"
      orphanLease = "22222222-2222-4222-8222-222222222222"
      orphanDatabase = "hinagata_cleanup_orphan"
      orphanToken = "33333333-3333-4333-8333-333333333333"
      orphanMarker = "hinagata:v1:" <> clusterUuid catalog <> ":" <> orphanToken
  execCheck connection (Encoding.encodeUtf8 ("CREATE DATABASE " <> orphanDatabase))
  execCheck connection (Encoding.encodeUtf8 ("COMMENT ON DATABASE " <> orphanDatabase <> " IS '" <> orphanMarker <> "'"))
  orphanOid <- queryInt connection (Encoding.encodeUtf8 ("SELECT oid FROM pg_database WHERE datname = '" <> orphanDatabase <> "'"))
  execCheck connection (Encoding.encodeUtf8 ("INSERT INTO hinagata_test.allocations (id, project_id, generation_id, run_id, database_name, database_oid, ownership_token, state) VALUES ('" <> orphanId <> "', 'baseline-test', '" <> generationText <> "', 'recovery-run', '" <> orphanDatabase <> "', " <> Text.pack (show orphanOid) <> "::oid, '" <> orphanToken <> "', 'Active')"))
  execCheck connection (Encoding.encodeUtf8 ("INSERT INTO hinagata_test.leases (id, allocation_id, run_id, state) VALUES ('" <> orphanLease <> "', '" <> orphanId <> "', 'recovery-run', 'Active')"))
  candidates <- orFail =<< planCleanup lifecycleConfig
  assert "free session lock classifies a positively owned active clone as orphaned" (case [disposition candidate | candidate <- candidates, allocationId candidate == orphanId] of [Orphaned] -> True; _ -> False)
  assert "cleanup preview leaves an orphaned database present" =<< ((== 1) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> orphanDatabase <> "'")))
  applied <- applyCleanup lifecycleConfig OrphansOnly [orphanId]
  assert "explicit apply removes a revalidated orphan" (applied == Right [Released orphanId])
  assert "orphaned clone is absent after apply" =<< ((== 0) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> orphanDatabase <> "'")))
  reapplied <- applyCleanup lifecycleConfig OrphansOnly [orphanId]
  assert "recovery release is idempotent" (reapplied == Right [AlreadyReleased orphanId])
  liveStarted <- newEmptyMVar
  releaseLive <- newEmptyMVar
  liveFinished <- newEmptyMVar
  _ <- forkIO (try @SomeException (withDatabase lifecycleConfig firstRef scenarioPlan (\info -> putMVar liveStarted info >> takeMVar releaseLive)) >>= putMVar liveFinished)
  liveInfo <- takeMVar liveStarted
  livePreview <- orFail =<< planCleanup lifecycleConfig
  let LeaseInfo {leaseId = liveLease} = liveInfo
      liveCandidates = [candidate | candidate@CleanupCandidate {leaseId = Just identifier} <- livePreview, identifier == liveLease]
  assert "held lease session lock appears live in cleanup preview" (case liveCandidates of [CleanupCandidate {disposition = Live}] -> True; _ -> False)
  liveAllocation <- case liveCandidates of [candidate] -> pure (allocationId candidate); _ -> fail "live allocation is absent"
  liveInspection <- inspectLease lifecycleConfig liveLease
  assert "direct lease inspection reports a live callback" (case liveInspection of Right (Just CleanupCandidate {disposition = Live}) -> True; _ -> False)
  livePreserve <- preserveLease lifecycleConfig liveLease
  assert "explicit preservation skips a live callback" (livePreserve == Right (Skipped liveAllocation Live))
  liveApply <- applyCleanup lifecycleConfig IncludeRetained [liveAllocation]
  assert "explicit apply skips a live callback" (liveApply == Right [Skipped liveAllocation Live])
  putMVar releaseLive ()
  liveResult <- timeout 10000000 (takeMVar liveFinished)
  assert "live callback releases normally after cleanup skips it" (case liveResult of Just (Right (Right _)) -> True; _ -> False)
  lostOwner <- withDatabase lifecycleConfig firstRef scenarioPlan $ \info@LeaseInfo {leaseId = lostLease} -> do
    let key = "lease:" <> lostLease
        statement = Encoding.encodeUtf8 ("SELECT pg_terminate_backend(pid)::text FROM pg_locks WHERE locktype = 'advisory' AND classid = 1212761905::oid AND objid = hashtext('" <> key <> "')::oid AND granted AND pid <> pg_backend_pid()")
    terminated <- queryText connection statement
    assert "lost-owner test terminates the held maintenance lock" (terminated == "true")
    pure info
  assert "lease scope reports loss of its owning maintenance session" (case lostOwner of Left _ -> True; Right _ -> False)
  lostCandidates <- orFail =<< planCleanup lifecycleConfig
  lostCandidate <- case [candidate | candidate@CleanupCandidate {state = "Active", disposition = Orphaned} <- lostCandidates] of
    [candidate] -> pure candidate
    _ -> fail "lost-owner allocation was not classified orphaned"
  recoveredOwner <- applyCleanup lifecycleConfig OrphansOnly [allocationId lostCandidate]
  assert "lost-owner clone requires explicit ownership-checked release" (recoveredOwner == Right [Released (allocationId lostCandidate)])
  interruptedLease <- newEmptyMVar
  continuedAfterLoss <- newIORef False
  lostDuringCallback <- timeout 10000000 $ withDatabase lifecycleConfig firstRef scenarioPlan $ \info@LeaseInfo {leaseId = lostLease} -> do
    putMVar interruptedLease info
    let key = "lease:" <> lostLease
        statement = Encoding.encodeUtf8 ("SELECT pg_terminate_backend(pid)::text FROM pg_locks WHERE locktype = 'advisory' AND classid = 1212761905::oid AND objid = hashtext('" <> key <> "')::oid AND granted AND pid <> pg_backend_pid()")
    terminated <- queryText connection statement
    assert "running-callback test terminates the held maintenance lock" (terminated == "true")
    threadDelay 30000000
    modifyIORef' continuedAfterLoss (const True)
  assert "ownership loss interrupts a still-running callback" (case lostDuringCallback of Just (Left LeaseError {cause = "lease ownership connection was lost during callback"}) -> True; _ -> False)
  ranAfterLoss <- readIORef continuedAfterLoss
  assert "interrupted callback does not continue after lease ownership loss" (not ranAfterLoss)
  LeaseInfo {leaseId = interruptedId} <- takeMVar interruptedLease
  interruptedInspection <- inspectLease lifecycleConfig interruptedId
  interruptedAllocation <- case interruptedInspection of
    Right (Just candidate@CleanupCandidate {state = "Active", disposition = Orphaned}) -> pure (allocationId candidate)
    _ -> fail "interrupted callback did not leave an inspectable orphan"
  interruptedRelease <- applyCleanup lifecycleConfig OrphansOnly [interruptedAllocation]
  assert "interrupted callback requires explicit ownership-checked cleanup" (interruptedRelease == Right [Released interruptedAllocation])
  let retainedId = "44444444-4444-4444-8444-444444444444"
      retainedLease = "55555555-5555-4555-8555-555555555555"
      retainedDatabase = "hinagata_cleanup_retained"
      retainedToken = "66666666-6666-4666-8666-666666666666"
      retainedMarker = "hinagata:v1:" <> clusterUuid catalog <> ":" <> retainedToken
  execCheck connection (Encoding.encodeUtf8 ("CREATE DATABASE " <> retainedDatabase))
  execCheck connection (Encoding.encodeUtf8 ("COMMENT ON DATABASE " <> retainedDatabase <> " IS '" <> retainedMarker <> "'"))
  retainedOid <- queryInt connection (Encoding.encodeUtf8 ("SELECT oid FROM pg_database WHERE datname = '" <> retainedDatabase <> "'"))
  execCheck connection (Encoding.encodeUtf8 ("INSERT INTO hinagata_test.allocations (id, project_id, generation_id, run_id, database_name, database_oid, ownership_token, state) VALUES ('" <> retainedId <> "', 'baseline-test', '" <> generationText <> "', 'recovery-run', '" <> retainedDatabase <> "', " <> Text.pack (show retainedOid) <> "::oid, '" <> retainedToken <> "', 'Preserved')"))
  execCheck connection (Encoding.encodeUtf8 ("INSERT INTO hinagata_test.leases (id, allocation_id, run_id, state) VALUES ('" <> retainedLease <> "', '" <> retainedId <> "', 'recovery-run', 'Preserved')"))
  retainedPreview <- orFail =<< planCleanup lifecycleConfig
  assert "preserved lease is classified as retained" (case [disposition candidate | candidate <- retainedPreview, allocationId candidate == retainedId] of [Retained] -> True; _ -> False)
  ordinary <- applyCleanup lifecycleConfig OrphansOnly [retainedId]
  assert "ordinary recovery skips a preserved database" (ordinary == Right [Skipped retainedId Retained])
  selected <- applyCleanup lifecycleConfig IncludeRetained [retainedId]
  assert "explicit retained selection releases a positively owned database" (selected == Right [Released retainedId])
  let foreignId = "77777777-7777-4777-8777-777777777777"
      foreignLease = "88888888-8888-4888-8888-888888888888"
      foreignDatabase = "hinagata_cleanup_foreign"
      foreignToken = "99999999-9999-4999-8999-999999999999"
  execCheck connection (Encoding.encodeUtf8 ("CREATE DATABASE " <> foreignDatabase))
  execCheck connection (Encoding.encodeUtf8 ("COMMENT ON DATABASE " <> foreignDatabase <> " IS 'foreign'"))
  foreignOid <- queryInt connection (Encoding.encodeUtf8 ("SELECT oid FROM pg_database WHERE datname = '" <> foreignDatabase <> "'"))
  execCheck connection (Encoding.encodeUtf8 ("INSERT INTO hinagata_test.allocations (id, project_id, generation_id, run_id, database_name, database_oid, ownership_token, state) VALUES ('" <> foreignId <> "', 'baseline-test', '" <> generationText <> "', 'recovery-run', '" <> foreignDatabase <> "', " <> Text.pack (show foreignOid) <> "::oid, '" <> foreignToken <> "', 'Active')"))
  execCheck connection (Encoding.encodeUtf8 ("INSERT INTO hinagata_test.leases (id, allocation_id, run_id, state) VALUES ('" <> foreignLease <> "', '" <> foreignId <> "', 'recovery-run', 'Active')"))
  foreignPreview <- orFail =<< planCleanup lifecycleConfig
  assert "altered marker is visible as foreign evidence" (case [disposition candidate | candidate <- foreignPreview, allocationId candidate == foreignId] of [Foreign] -> True; _ -> False)
  foreignApply <- applyCleanup lifecycleConfig IncludeRetained [foreignId]
  assert "apply refuses a same-prefix database with altered ownership marker" (case foreignApply of Right [Refused identifier _] -> identifier == foreignId; _ -> False)
  assert "refused foreign database remains present" =<< ((== 1) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> foreignDatabase <> "'")))
  execCheck connection (Encoding.encodeUtf8 ("DROP DATABASE " <> foreignDatabase))
  let ambiguousId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      ambiguousDatabase = "hinagata_cleanup_ambiguous"
      ambiguousToken = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  execCheck connection (Encoding.encodeUtf8 ("CREATE DATABASE " <> ambiguousDatabase))
  execCheck connection (Encoding.encodeUtf8 ("INSERT INTO hinagata_test.allocations (id, project_id, generation_id, run_id, database_name, ownership_token, state) VALUES ('" <> ambiguousId <> "', 'baseline-test', '" <> generationText <> "', 'recovery-run', '" <> ambiguousDatabase <> "', '" <> ambiguousToken <> "', 'Allocating')"))
  ambiguousPreview <- orFail =<< planCleanup lifecycleConfig
  assert "unbound allocation remains ambiguous even when its name exists" (case [disposition candidate | candidate <- ambiguousPreview, allocationId candidate == ambiguousId] of [Ambiguous] -> True; _ -> False)
  ambiguousApply <- applyCleanup lifecycleConfig IncludeRetained [ambiguousId]
  assert "apply refuses an unbound database identity" (case ambiguousApply of Right [Refused identifier _] -> identifier == ambiguousId; _ -> False)
  assert "ambiguous same-prefix database remains present" =<< ((== 1) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> ambiguousDatabase <> "'")))
  execCheck connection (Encoding.encodeUtf8 ("DROP DATABASE " <> ambiguousDatabase))
  let protectedId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  execCheck connection (Encoding.encodeUtf8 ("INSERT INTO hinagata_test.allocations (id, project_id, generation_id, run_id, database_name, ownership_token, state) VALUES ('" <> protectedId <> "', 'baseline-test', '" <> generationText <> "', 'recovery-run', '" <> databaseNameText database <> "', '" <> ambiguousToken <> "', 'Allocating')"))
  protectedApply <- applyCleanup lifecycleConfig IncludeRetained [protectedId]
  assert "maintenance database is protected even with a catalog allocation" (case protectedApply of Right [Refused identifier _] -> identifier == protectedId; _ -> False)

retentionLifecycleTests :: HinagataConfig -> BaselineRef -> FixturePlan -> PQ.Connection -> CatalogIdentity -> IO ()
retentionLifecycleTests lifecycleConfig firstRef scenarioPlan connection catalog = do
  classifiedSuccess <- withDatabaseClassified lifecycleConfig firstRef scenarioPlan PreserveFailures not (\_ -> pure True)
  assert "successful classified value is returned unchanged and released" (case classifiedSuccess of Right LeaseOutcome {callbackValue = True, leaseDisposition = LeaseReleased, cleanupDiagnostic = Nothing} -> True; _ -> False)
  classifiedFailure <- withDatabaseClassified lifecycleConfig firstRef scenarioPlan PreserveFailures not (\_ -> pure False)
  preservedInfo <- case classifiedFailure of
    Right LeaseOutcome {callbackValue = False, leaseDisposition = LeasePreserved, cleanupDiagnostic = Nothing, leaseInfo} -> pure leaseInfo
    _ -> fail "classified failure did not preserve its clone"
  preservedConnection <- PQ.connectdb (Encoding.encodeUtf8 (connectionStringText (renderConnectionString (applicationTarget preservedInfo))))
  preservedRows <- queryInt preservedConnection "SELECT count(*) FROM items"
  PQ.finish preservedConnection
  assert "preserved callback value leaves its scenario rows inspectable" (preservedRows == 3)
  let LeaseInfo {leaseId = preservedId} = preservedInfo
  preservedRelease <- releaseLease lifecycleConfig preservedId
  assert "classified failure remains explicitly releasable by lease ID" (case preservedRelease of Right (Released _) -> True; _ -> False)
  detachedInfo <- orFail =<< acquireDetached lifecycleConfig firstRef scenarioPlan
  let LeaseInfo {leaseId = detachedId} = detachedInfo
  detachedPreview <- orFail =<< planCleanup lifecycleConfig
  assert "detached acquisition is retained without an active callback slot" (case [disposition candidate | candidate@CleanupCandidate {leaseId = Just identifier} <- detachedPreview, identifier == detachedId] of [Retained] -> True; _ -> False)
  detachedInspection <- inspectLease lifecycleConfig detachedId
  assert "direct inspection reports a detached lease" (case detachedInspection of Right (Just CleanupCandidate {state = "Detached", disposition = Retained}) -> True; _ -> False)
  let detachedDatabase = databaseNameText (connectionDatabase (applicationTarget detachedInfo))
  detachedToken <- queryText connection (Encoding.encodeUtf8 ("SELECT a.ownership_token::text FROM hinagata_test.allocations a JOIN hinagata_test.leases l ON l.allocation_id = a.id WHERE l.id = '" <> detachedId <> "'"))
  execCheck connection (Encoding.encodeUtf8 ("COMMENT ON DATABASE \"" <> detachedDatabase <> "\" IS 'foreign'"))
  foreignInspection <- inspectLease lifecycleConfig detachedId
  assert "inspection exposes changed ownership evidence on a retained clone" (case foreignInspection of Right (Just CleanupCandidate {disposition = Foreign}) -> True; _ -> False)
  foreignPreserve <- preserveLease lifecycleConfig detachedId
  assert "explicit preservation refuses changed ownership evidence" (case foreignPreserve of Right (Refused _ _) -> True; _ -> False)
  let detachedMarker = "hinagata:v1:" <> clusterUuid catalog <> ":" <> Encoding.decodeUtf8 detachedToken
  execCheck connection (Encoding.encodeUtf8 ("COMMENT ON DATABASE \"" <> detachedDatabase <> "\" IS '" <> detachedMarker <> "'"))
  detachedPreserve <- preserveLease lifecycleConfig detachedId
  assert "detached lease can be explicitly preserved" (case detachedPreserve of Right (Preserved _) -> True; _ -> False)
  detachedRePreserve <- preserveLease lifecycleConfig detachedId
  assert "explicit lease preservation is idempotent" (case detachedRePreserve of Right (Preserved _) -> True; _ -> False)
  preservedInspection <- inspectLease lifecycleConfig detachedId
  assert "explicit preservation updates the lease state" (case preservedInspection of Right (Just CleanupCandidate {state = "Preserved", disposition = Retained}) -> True; _ -> False)
  detachedRelease <- releaseLease lifecycleConfig detachedId
  assert "detached lease releases by explicit ID" (case detachedRelease of Right (Released _) -> True; _ -> False)
  releasedInspection <- inspectLease lifecycleConfig detachedId
  assert "released lease remains inspectable by ID" (case releasedInspection of Right (Just CleanupCandidate {state = "Released", disposition = Missing}) -> True; _ -> False)
  detachedReRelease <- releaseLease lifecycleConfig detachedId
  assert "detached release by lease ID is idempotent" (case detachedReRelease of Right (AlreadyReleased _) -> True; _ -> False)
  dropBlockedInfo <- orFail =<< acquireDetached lifecycleConfig firstRef scenarioPlan
  let LeaseInfo {leaseId = dropBlockedId, applicationTarget = dropBlockedTarget} = dropBlockedInfo
      preparedGid = "hinagata-drop-" <> dropBlockedId
      preparedConnectionString = Encoding.encodeUtf8 (connectionStringText (renderConnectionString dropBlockedTarget))
      dropBlockedDatabase = databaseNameText (connectionDatabase dropBlockedTarget)
  bracket (PQ.connectdb preparedConnectionString) PQ.finish $ \preparedConnection -> do
    execCheck preparedConnection "BEGIN"
    execCheck preparedConnection "INSERT INTO items (id, note) VALUES (123456, 'prepared drop blocker')"
    execCheck preparedConnection (Encoding.encodeUtf8 ("PREPARE TRANSACTION '" <> preparedGid <> "'"))
  blockedRelease <- releaseLease lifecycleConfig dropBlockedId
  assert "prepared transaction makes force drop fail" (case blockedRelease of Left _ -> True; _ -> False)
  assert "failed drop retains its database" =<< ((== 1) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> dropBlockedDatabase <> "'")))
  assert "failed drop records state and diagnostic" =<< ((== 1) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM hinagata_test.allocations a JOIN hinagata_test.leases l ON l.allocation_id = a.id WHERE l.id = '" <> dropBlockedId <> "' AND a.state = 'CleanupFailed' AND l.state = 'CleanupFailed' AND length(a.last_error) > 0")))
  bracket (PQ.connectdb preparedConnectionString) PQ.finish $ \preparedConnection ->
    execCheck preparedConnection (Encoding.encodeUtf8 ("ROLLBACK PREPARED '" <> preparedGid <> "'"))
  retriedRelease <- releaseLease lifecycleConfig dropBlockedId
  assert "failed drop can be retried after its blocker is cleared" (case retriedRelease of Right (Released _) -> True; _ -> False)
  callbackBlocked <- withDatabaseClassified lifecycleConfig firstRef scenarioPlan ReleaseAlways (const False) $ \LeaseInfo {leaseId, applicationTarget} -> do
    let connectionString = Encoding.encodeUtf8 (connectionStringText (renderConnectionString applicationTarget))
        callbackGid = "hinagata-callback-drop-" <> leaseId
    bracket (PQ.connectdb connectionString) PQ.finish $ \preparedConnection -> do
      execCheck preparedConnection "BEGIN"
      execCheck preparedConnection "INSERT INTO items (id, note) VALUES (123457, 'callback drop blocker')"
      execCheck preparedConnection (Encoding.encodeUtf8 ("PREPARE TRANSACTION '" <> callbackGid <> "'"))
  callbackBlockedInfo <- case callbackBlocked of
    Right LeaseOutcome {leaseInfo, leaseDisposition = LeaseCleanupFailed, cleanupDiagnostic = Just _} -> pure leaseInfo
    _ -> fail "callback force-drop failure was not reported separately from its callback result"
  let LeaseInfo {leaseId = callbackBlockedId, applicationTarget = callbackBlockedTarget} = callbackBlockedInfo
      callbackConnectionString = Encoding.encodeUtf8 (connectionStringText (renderConnectionString callbackBlockedTarget))
      callbackPreparedGid = "hinagata-callback-drop-" <> callbackBlockedId
  assert "callback force-drop failure retains its diagnostic" =<< ((== 1) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM hinagata_test.allocations a JOIN hinagata_test.leases l ON l.allocation_id = a.id WHERE l.id = '" <> callbackBlockedId <> "' AND a.state = 'CleanupFailed' AND l.state = 'CleanupFailed' AND length(a.last_error) > 0")))
  bracket (PQ.connectdb callbackConnectionString) PQ.finish $ \preparedConnection ->
    execCheck preparedConnection (Encoding.encodeUtf8 ("ROLLBACK PREPARED '" <> callbackPreparedGid <> "'"))
  callbackRetried <- releaseLease lifecycleConfig callbackBlockedId
  assert "callback force-drop failure can be retried by lease ID" (case callbackRetried of Right (Released _) -> True; _ -> False)
  assert "successful callback cleanup retry clears the diagnostic" =<< ((== 1) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM hinagata_test.allocations a JOIN hinagata_test.leases l ON l.allocation_id = a.id WHERE l.id = '" <> callbackBlockedId <> "' AND a.state = 'Released' AND a.last_error IS NULL")))
  thrownInfo <- newEmptyMVar
  classifiedThrown <- try @SomeException (withDatabaseClassified lifecycleConfig firstRef scenarioPlan PreserveFailures (const False) (\info -> putMVar thrownInfo info >> fail "intentional classified exception"))
  assert "classified callback exception keeps its original exception" (case classifiedThrown of Left _ -> True; Right _ -> False)
  LeaseInfo {leaseId = thrownId} <- takeMVar thrownInfo
  thrownPreview <- orFail =<< planCleanup lifecycleConfig
  assert "thrown callback preserves its clone under policy" (case [disposition candidate | candidate@CleanupCandidate {leaseId = Just identifier} <- thrownPreview, identifier == thrownId] of [Retained] -> True; _ -> False)
  thrownRelease <- releaseLease lifecycleConfig thrownId
  assert "exception-preserved lease releases by explicit ID" (case thrownRelease of Right (Released _) -> True; _ -> False)
  cancelledInfo <- newEmptyMVar
  cancelledDone <- newEmptyMVar
  cancelledThread <-
    forkIO
      ( try @SomeException
          (withDatabaseClassified lifecycleConfig firstRef scenarioPlan PreserveFailures (const False) (\info -> putMVar cancelledInfo info >> threadDelay 30000000 >> pure ()))
          >>= putMVar cancelledDone
      )
  LeaseInfo {leaseId = cancelledId, applicationTarget = cancelledTarget} <- takeMVar cancelledInfo
  killThread cancelledThread
  cancelledResult <- timeout 10000000 (takeMVar cancelledDone)
  assert "callback cancellation rethrows its asynchronous exception" (case cancelledResult of Just (Left _) -> True; _ -> False)
  assert "callback cancellation releases despite failure-preservation policy" =<< ((== 1) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM hinagata_test.leases WHERE id = '" <> cancelledId <> "' AND state = 'Released'")))
  assert "callback cancellation drops its database" =<< ((== 0) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> databaseNameText (connectionDatabase cancelledTarget) <> "'")))

generationLifecycleTests :: HinagataConfig -> BaselineSpec -> BaselineRef -> FixturePlan -> FilePath -> FilePath -> PQ.Connection -> IORef Int -> SqlIdentifier -> ConnectionTarget -> SqlIdentifier -> IO ()
generationLifecycleTests lifecycleConfig baselineSpec firstRef scenarioPlan fixtureRoot bundleRoot connection migrationCalls messageSetting target catalogSchema = do
  startingCalls <- readIORef migrationCalls
  changed <- ensureBaseline baselineSpec {migrationRevision = Just "migration-v2", compareAgainst = Just firstRef}
  (changedRef, changedReport) <- orFail changed
  changedCalls <- readIORef migrationCalls
  assert "migration revision creates a distinct baseline with an explained change" (baselineDatabase changedRef /= baselineDatabase firstRef && kind changedReport == Built && fmap changedComponents (comparison changedReport) == Just [MigrationRevision] && changedCalls == startingCalls + 1)
  ByteString.writeFile (fixtureRoot </> "good" </> "fixture.sql") "INSERT INTO items (id, note) VALUES (1, 'changed first'); INSERT INTO items (id, note) VALUES (2, 'second');"
  changedPlan <- bundleOrFail =<< compileFixtures (BundleConfig fixtureRoot bundleRoot (positive 1048576) (positive 65536)) [fixtureName "good"]
  allocationsBeforeConflict <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations"
  conflicting <- withDatabase lifecycleConfig firstRef changedPlan (\_ -> pure ())
  allocationsAfterConflict <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations"
  assert "conflicting captured fixture refused before allocation" (case conflicting of Left _ -> allocationsBeforeConflict == allocationsAfterConflict; Right _ -> False)
  ByteString.writeFile (fixtureRoot </> "good" </> "fixture.sql") "INSERT INTO items (id, note) VALUES (1, 'first'); INSERT INTO items (id, note) VALUES (2, 'second');"
  changedFixture <- ensureBaseline baselineSpec {basePlan = changedPlan, compareAgainst = Just firstRef}
  assert "base fixture bytes select a new generation with an explained change" (case changedFixture of Right (ref, report) -> baselineDatabase ref /= baselineDatabase firstRef && kind report == Built && fmap changedComponents (comparison report) == Just [BaseFixtures]; _ -> False)
  changedHook <- ensureBaseline baselineSpec {verificationRevision = Just "verify-v2", compareAgainst = Just firstRef}
  assert "verification hook revision is independently explained" (case changedHook of Right (_, report) -> kind report == Built && fmap changedComponents (comparison report) == Just [VerificationRevision]; _ -> False)
  let changedRoleConfig = lifecycleConfig {applicationSettings = [RoleSetting messageSetting "notice"]}
  changedRole <- ensureBaseline baselineSpec {configuration = changedRoleConfig, compareAgainst = Just firstRef}
  assert "application role setting is independently explained without its value" (case changedRole of Right (_, report) -> kind report == Built && fmap changedComponents (comparison report) == Just [ApplicationRoleSettings]; _ -> False)
  failed <- ensureBaseline baselineSpec {migrationRevision = Just "migration-v3", verificationHook = \_ -> pure (Left "verification failed")}
  assert "failed rebuild remains unpublished" (case failed of Left _ -> True; Right _ -> False)
  missingExtension <- ensureBaseline baselineSpec {migrationRevision = Just "migration-v4", requiredExtensions = ["not_installed"]}
  assert "missing declared extension prevents publication" (case missingExtension of Left _ -> True; Right _ -> False)
  unknownFirst <- ensureBaseline baselineSpec {migrationRevision = Nothing}
  unknownSecond <- ensureBaseline baselineSpec {migrationRevision = Nothing}
  assert "unknown migration revision disables persistent reuse" (case (unknownFirst, unknownSecond) of (Right (left, leftReport), Right (right, rightReport)) -> baselineDatabase left /= baselineDatabase right && kind leftReport == Built && kind rightReport == Built; _ -> False)
  oldReady <- ensureBaseline baselineSpec
  assert "failed rebuild preserves earlier ready baseline" (case oldReady of Right (ref, report) -> baselineDatabase ref == baselineDatabase firstRef && kind report == Reused; _ -> False)
  firstCold <- newEmptyMVar
  secondCold <- newEmptyMVar
  let concurrentSpec = baselineSpec {migrationRevision = Just "migration-concurrent"}
  _ <- forkIO (ensureBaseline concurrentSpec >>= putMVar firstCold)
  _ <- forkIO (ensureBaseline concurrentSpec >>= putMVar secondCold)
  concurrentFirst <- timeout 10000000 (takeMVar firstCold)
  concurrentSecond <- timeout 10000000 (takeMVar secondCold)
  assert "concurrent cold callers publish one generation" (case (concurrentFirst, concurrentSecond) of (Just (Right (left, leftReport)), Just (Right (right, rightReport))) -> baselineDatabase left == baselineDatabase right && [kind leftReport, kind rightReport] `elem` [[Built, Reused], [Reused, Built]]; _ -> False)
  builderEntered <- newEmptyMVar
  builderBlock <- newEmptyMVar
  builderDone <- newEmptyMVar
  let deathSpec = baselineSpec {migrationRevision = Just "migration-builder-death"}
      blockedBuilder = deathSpec {migrationHook = \_ -> putMVar builderEntered () >> takeMVar builderBlock >> pure (Right ())}
  builderThread <- forkIO (try @SomeException (ensureBaseline blockedBuilder) >>= putMVar builderDone)
  builderStarted <- timeout 10000000 (takeMVar builderEntered)
  assert "builder reaches migration after recording a generation" (case builderStarted of Just () -> True; _ -> False)
  cancelledWaiterDone <- newEmptyMVar
  cancelledWaiter <- forkIO (try @SomeException (ensureBaseline deathSpec) >>= putMVar cancelledWaiterDone)
  threadDelay 100000
  killThread cancelledWaiter
  cancelledWaiterResult <- timeout 10000000 (takeMVar cancelledWaiterDone)
  assert "cancelling one baseline waiter does not block indefinitely" (case cancelledWaiterResult of Just (Left _) -> True; _ -> False)
  expiredWaiter <- timeout 10000000 (ensureBaseline (deathSpec {configuration = lifecycleConfig {setupDeadlineMs = positive 200}}))
  assert "a waiter deadline expires while the builder still holds its lock" (case expiredWaiter of Just (Left _) -> True; _ -> False)
  survivingWaiterDone <- newEmptyMVar
  _ <- forkIO (ensureBaseline deathSpec >>= putMVar survivingWaiterDone)
  threadDelay 100000
  killThread builderThread
  builderResult <- timeout 10000000 (takeMVar builderDone)
  assert "builder process death releases its coordination session" (case builderResult of Just (Left _) -> True; _ -> False)
  survivor <- timeout 10000000 (takeMVar survivingWaiterDone)
  assert "a later waiter builds a ready generation after builder death" (case survivor of Just (Right (_, report)) -> kind report == Built; _ -> False)
  interruptedRecords <- queryInt connection "SELECT count(*) FROM hinagata_test.generations WHERE fingerprint_manifest->>'manifest' LIKE '%migration-builder-death%' AND state = 'Failed'"
  survivingRecords <- queryInt connection "SELECT count(*) FROM hinagata_test.generations WHERE fingerprint_manifest->>'manifest' LIKE '%migration-builder-death%' AND state = 'Ready'"
  assert "interrupted build becomes Failed while survivor is ready" (interruptedRecords == 1 && survivingRecords == 1)
  retired <- retireBaseline lifecycleConfig changedRef
  assert "sealed baseline retires under positive ownership" (retired == Right ())
  assert "retired template database is absent" =<< ((== 0) <$> queryInt connection (Encoding.encodeUtf8 ("SELECT count(*) FROM pg_database WHERE datname = '" <> databaseNameText (baselineDatabase changedRef) <> "'")))
  retiredRecord <- queryText connection (Encoding.encodeUtf8 ("SELECT state FROM hinagata_test.generations WHERE database_name = '" <> databaseNameText (baselineDatabase changedRef) <> "'"))
  assert "retired generation remains as a catalog tombstone" (retiredRecord == "Retiring")
  retiredAgain <- retireBaseline lifecycleConfig changedRef
  assert "retirement is idempotent after the owned template disappears" (retiredAgain == Right ())
  staleClone <- withDatabase lifecycleConfig changedRef scenarioPlan (\_ -> pure ())
  assert "retired baseline cannot allocate another clone" (case staleClone of Left _ -> True; _ -> False)
  replacement <- ensureBaseline baselineSpec {migrationRevision = Just "migration-v2"}
  assert "retirement permits a new ready generation for the same fingerprint" (case replacement of Right (ref, report) -> kind report == Built && baselineDatabase ref /= baselineDatabase changedRef; _ -> False)
  let tamperedName = databaseNameText (baselineDatabase firstRef)
  execCheck connection (Encoding.encodeUtf8 ("COMMENT ON DATABASE \"" <> tamperedName <> "\" IS 'foreign'"))
  tampered <- ensureBaseline baselineSpec
  assert "ready generation with altered marker is refused" (case tampered of Left _ -> True; Right _ -> False)
  execCheck connection "DROP TABLE hinagata_test.leases"
  incompleteCatalog <- ensureCatalog target catalogSchema defaultSessionOptions
  assert "incomplete version-1 catalog is refused" (case incompleteCatalog of Left _ -> True; _ -> False)

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
  read . ByteString.unpack <$> queryText connection statement

queryText :: PQ.Connection -> ByteString.ByteString -> IO ByteString.ByteString
queryText connection statement = do
  result <- PQ.exec connection statement
  case result of
    Nothing -> fail "PostgreSQL returned no result"
    Just value -> do
      cell <- PQ.getvalue value (PQ.toRow (0 :: Int)) (PQ.toColumn (0 :: Int))
      maybe (fail "PostgreSQL returned null") pure cell

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
