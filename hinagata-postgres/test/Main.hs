module Main (main) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Database.PostgreSQL.LibPQ qualified as PQ
import Hinagata.Config
import Hinagata.Connection
import Hinagata.Fixture.Bundle
import Hinagata.Fixture.Types
import Hinagata.Postgres.Baseline hiding (elapsedMs)
import Hinagata.Postgres.Error (LoadError (..), LoadPhase (..))
import Hinagata.Postgres.Lease
import Hinagata.Postgres.Load
import Hinagata.Postgres.Ownership
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

lifecycleTests :: ConnectionTarget -> PQ.Connection -> Host -> Port -> Text -> DatabaseName -> FilePath -> FilePath -> FixturePlan -> IO ()
lifecycleTests target connection host port adminUser database fixtureRoot bundleRoot goodPlan = do
  catalogSchema <- orFail (mkSqlIdentifier "hinagata_test")
  firstCatalog <- ensureCatalog target catalogSchema defaultSessionOptions
  secondCatalog <- ensureCatalog target catalogSchema defaultSessionOptions
  assert "catalog initializes and reuses one cluster identity" (case (firstCatalog, secondCatalog) of (Right first, Right second) -> first == second && formatVersion first == 1; _ -> False)
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
  let adminRole = AccessConfig adminUser database Nothing
      setupRole = AccessConfig "hinagata_setup" database Nothing
      appRole = AccessConfig "hinagata_app" database Nothing
      lifecycleConfig =
        HinagataConfig
          { endpoint = EndpointConfig host port,
            project = projectId,
            fixtureRoot,
            bundleRoot,
            maintenanceDatabase = database,
            maintenanceSchema = catalogSchema,
            administration = adminRole,
            setup = setupRole,
            application = appRole,
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
      baselineSpec = BaselineSpec lifecycleConfig goodPlan (Just "migration-v1") (Just "verify-v1") ["plpgsql"] (Just "C") migrate verify
  firstBaseline <- ensureBaseline baselineSpec
  secondBaseline <- ensureBaseline baselineSpec
  (firstRef, firstReport) <- orFail firstBaseline
  (secondRef, secondReport) <- orFail secondBaseline
  calls <- readIORef migrationCalls
  assert "baseline builds once and reuses a sealed generation" (baselineDatabase firstRef == baselineDatabase secondRef && kind firstReport == Built && kind secondReport == Reused && calls == 1)
  recordedManifest <- queryText connection "SELECT fingerprint_manifest::text FROM hinagata_test.generations WHERE state = 'Ready' LIMIT 1"
  assert "fingerprint manifest omits raw role-setting values" (not ("warning" `ByteString.isInfixOf` recordedManifest))
  rotatedPassword <- orFail (mkSecret "rotated-passphrase")
  let rotatedConfig = lifecycleConfig {administration = adminRole {password = Just rotatedPassword}, setup = setupRole {password = Just rotatedPassword}, application = appRole {password = Just rotatedPassword}}
  rotated <- ensureBaseline baselineSpec {configuration = rotatedConfig}
  assert "credential rotation does not invalidate a baseline" (case rotated of Right (ref, report) -> baselineDatabase ref == baselineDatabase firstRef && kind report == Reused; _ -> False)
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
  changed <- ensureBaseline baselineSpec {migrationRevision = Just "migration-v2"}
  (changedRef, changedReport) <- orFail changed
  changedCalls <- readIORef migrationCalls
  assert "migration revision creates a distinct baseline" (baselineDatabase changedRef /= baselineDatabase firstRef && kind changedReport == Built && changedCalls == 2)
  ByteString.writeFile (fixtureRoot </> "good" </> "fixture.sql") "INSERT INTO items (id, note) VALUES (1, 'changed first'); INSERT INTO items (id, note) VALUES (2, 'second');"
  changedPlan <- bundleOrFail =<< compileFixtures (BundleConfig fixtureRoot bundleRoot (positive 1048576) (positive 65536)) [fixtureName "good"]
  allocationsBeforeConflict <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations"
  conflicting <- withDatabase lifecycleConfig firstRef changedPlan (\_ -> pure ())
  allocationsAfterConflict <- queryInt connection "SELECT count(*) FROM hinagata_test.allocations"
  assert "conflicting captured fixture refused before allocation" (case conflicting of Left _ -> allocationsBeforeConflict == allocationsAfterConflict; Right _ -> False)
  ByteString.writeFile (fixtureRoot </> "good" </> "fixture.sql") "INSERT INTO items (id, note) VALUES (1, 'first'); INSERT INTO items (id, note) VALUES (2, 'second');"
  changedFixture <- ensureBaseline baselineSpec {basePlan = changedPlan}
  assert "base fixture bytes select a new generation" (case changedFixture of Right (ref, report) -> baselineDatabase ref /= baselineDatabase firstRef && kind report == Built; _ -> False)
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
