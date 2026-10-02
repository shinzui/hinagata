module Main (main) where

import Control.Monad (replicateM_)
import Data.ByteString.Char8 qualified as ByteString
import Data.List (isInfixOf, sort)
import Data.Text qualified as Text
import Hinagata.Config (AccessConfig (..), CloneStrategy (..), HinagataConfig (..), SchemaGrant (..), SchemaPrivilege (..), hinagataConfig, hinagataEnvironmentBindings)
import Hinagata.Connection
import Hinagata.Fixture.Bundle qualified as Bundle
import Hinagata.Fixture.Graph
import Hinagata.Fixture.Manifest
import Hinagata.Fixture.SqlPolicy
import Hinagata.Fixture.Types
import Hinagata.Prelude
import Hinagata.Types
import Settei qualified
import Settei.Env qualified as Env
import System.Directory (createDirectoryIfMissing, createFileLink)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), withBinaryFile)
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--csv-memory-probe", size, workspace] -> csvMemoryProbe (read size) workspace
    _ -> regressionTests

regressionTests :: IO ()
regressionTests = do
  let a = fixture "a" ["b", "c"]
      b = fixture "b" ["d"]
      c = fixture "c" ["d"]
      d = fixture "d" []
  assert "diamond closure" (fmap (map name) (resolveFixtures [a, b, c, d] [fixtureName "a"]) == Right (map fixtureName ["d", "b", "c", "a"]))
  assert "stable root order" (fmap (map name) (resolveFixtures [a, b, c, d] (map fixtureName ["c", "a"])) == Right (map fixtureName ["d", "c", "b", "a"]))
  assert "cycle path" (resolveFixtures [fixture "a" ["b"], fixture "b" ["c"], fixture "c" ["a"]] [fixtureName "a"] == Left (FixtureCycle (map fixtureName ["a", "b", "c", "a"])))
  assert "missing dependency path" (resolveFixtures [fixture "a" ["b"]] [fixtureName "a"] == Left (MissingFixture (fixtureName "b") (map fixtureName ["a", "b"])))
  assert "duplicate definition" (resolveFixtures [a, a] [fixtureName "a"] == Left (DuplicateFixture (fixtureName "a")))
  assert "Unicode byte limit" (either (const True) (const False) (mkDatabaseName (Text.replicate 32 "é")))
  assert "quoted SQL identifier" (fmap quoteSqlIdentifier (mkSqlIdentifier "x\"y") == Right "\"x\"\"y\"")
  assert "zero port rejected" (either (const True) (const False) (mkPort 0))
  assert "socket must be absolute" (either (const True) (const False) (socketDirectory "relative"))
  let target = do
        host <- socketDirectory "/tmp/a b'c\\d"
        port <- mkPort 5432
        database <- mkDatabaseName "example"
        password <- mkSecret "p'\\secret"
        mkConnectionTarget host port "service" database (Just password)
  assert "keyword escaping" (fmap (connectionStringText . renderConnectionString) target == Right "host='/tmp/a b\\'c\\\\d' port='5432' user='service' dbname='example' password='p\\'\\\\secret'")
  assert "connection display redacts password" (all (not . (`isInfixOf` show target)) ["p'", "secret"])
  let validManifest =
        ByteString.pack
          ( unlines
              [ "name: example",
                "include: [common]",
                "steps:",
                "  - sql: prepare.sql",
                "  - copy:",
                "      table: {schema: app, name: members}",
                "      columns: [id, email]",
                "      file: members.csv",
                "      format: csv",
                "      header: true"
              ]
          )
  assert
    "manifest ordering"
    ( fmap (steps . manifestDefinition) (decodeManifest (fixtureName "example") validManifest)
        == Right
          [ SqlFile "prepare.sql",
            CopyCsv
              CopySpec
                { schema = sqlIdentifier "app",
                  table = sqlIdentifier "members",
                  columns = map sqlIdentifier ["id", "email"],
                  file = "members.csv",
                  header = True
                }
          ]
    )
  assert "unknown manifest fields rejected" (isManifestError (decodeManifest (fixtureName "example") (ByteString.pack "name: example\nunknown: true\nsteps: [{sql: fixture.sql}]\n")))
  assert "empty explicit steps rejected" (isManifestError (decodeManifest (fixtureName "example") (ByteString.pack "name: example\nsteps: []\n")))
  assert "directory/name mismatch rejected" (isManifestError (decodeManifest (fixtureName "other") validManifest))
  assert "path traversal rejected" (isManifestError (decodeManifest (fixtureName "example") (ByteString.pack "name: example\nsteps: [{sql: ../outside.sql}]\n")))
  assert "transaction control rejected" (checkSqlPolicy (ByteString.pack "/* comment */ BEGIN; SELECT 1") == Left (ForbiddenStatement "begin"))
  assert "nested comment does not conceal command" (checkSqlPolicy (ByteString.pack "/* outer /* nested */ end */ COPY x FROM STDIN") == Left (ForbiddenStatement "copy"))
  assert "dollar function body is opaque" (checkSqlPolicy (ByteString.pack "CREATE FUNCTION f() RETURNS void AS $$ BEGIN; COPY x FROM STDIN; END; $$ LANGUAGE plpgsql;") == Right ())
  assert "escape string is opaque" (checkSqlPolicy (ByteString.pack "SELECT E'abc\\'; COPY x FROM STDIN';") == Right ())
  assert "psql command rejected" (checkSqlPolicy (ByteString.pack "  \\i fixture.sql") == Left PsqlCommand)
  assert "PREPARE TRANSACTION rejected" (checkSqlPolicy (ByteString.pack "PREPARE TRANSACTION 'x'") == Left (ForbiddenStatement "TRANSACTION"))
  assert "SQL PREPARE remains allowed" (checkSqlPolicy (ByteString.pack "PREPARE q AS SELECT 1") == Right ())
  assert
    "all top-level transaction forms rejected"
    ( all
        (isSqlPolicyError . checkSqlPolicy . ByteString.pack)
        ["START TRANSACTION", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT x", "RELEASE SAVEPOINT x"]
    )
  assert "standard string and quoted identifier are opaque" (checkSqlPolicy (ByteString.pack "SELECT 'BEGIN; COPY', \"COMMIT;\" FROM x;") == Right ())
  configTests
  bundleTests

-- | Run this in a fresh process with +RTS -s. The fixture data is generated
-- and captured in fixed chunks so maximum live residency can be compared for
-- 1x and 10x CSV inputs without materializing the CSV in this test process.
csvMemoryProbe :: Int -> FilePath -> IO ()
csvMemoryProbe byteCount workspace = do
  let fixtureRoot = workspace </> "fixtures"
      fixtureDirectory = fixtureRoot </> "bulk"
      bundleRoot = workspace </> "bundles"
      chunk = ByteString.replicate 65536 'A'
  createDirectoryIfMissing True fixtureDirectory
  ByteString.writeFile (fixtureDirectory </> "fixture.yaml") "name: bulk\nsteps:\n  - copy:\n      table: {schema: public, name: bulk}\n      columns: [payload]\n      file: bulk.csv\n      format: csv\n      header: false\n"
  withBinaryFile (fixtureDirectory </> "bulk.csv") WriteMode $ \handle ->
    replicateM_ (byteCount `div` ByteString.length chunk) (ByteString.hPut handle chunk)
  let config = Bundle.BundleConfig fixtureRoot bundleRoot (positive 1024) (positive 65536)
  result <- Bundle.compileFixtures config [fixtureName "bulk"]
  case result of
    Right plan -> putStrLn (Text.unpack (Bundle.planDigest plan))
    Left problem -> fail (show problem)

configTests :: IO ()
configTests = do
  validated <- case hinagataEnvironmentBindings of
    Right result -> pure result
    Left errors -> fail (show errors)
  assert "explicit environment binding count" (length (Env.bindingsList validated) == 30)
  assert "every declared setting has an environment binding" (sort (map Settei.schemaSettingKey (Settei.schemaPossible (Settei.describe hinagataConfig))) == sort (map Env.bindingKey (Env.bindingsList validated)))
  let low =
        sourceOrFail
          "config"
          Settei.BuiltInSource
          [ ("endpoint.host", "/tmp/postgresql"),
            ("endpoint.port", "5432"),
            ("project.id", "example"),
            ("fixture.root", "/tmp/fixtures"),
            ("bundle.root", "/tmp/bundles"),
            ("maintenance.database", "postgres"),
            ("administration.user", "admin"),
            ("administration.database", "postgres"),
            ("setup.user", "migrator"),
            ("setup.database", "template"),
            ("application.user", "service"),
            ("application.database", "testdb")
          ]
      env =
        Env.environmentSource
          validated
          ( Env.envSnapshot
              [ ("HINAGATA_APPLICATION_USER", "app_override"),
                ("HINAGATA_APPLICATION_PASSWORD", "top-secret-credential"),
                ("HINAGATA_CLONE_STRATEGY", "FILE_COPY")
              ]
          )
      resolved = Settei.resolve Settei.defaultResolveOptions [low, env] hinagataConfig
  case Settei.answer resolved of
    Left errors -> fail (Text.unpack (Settei.renderErrorsText errors))
    Right config -> do
      assert "later Settei source wins" (user (application config) == "app_override")
      assert "clone strategy supplied explicitly" (cloneStrategy config == FileCopy)
      assert "admin and app roles stay separate" (user (administration config) == "admin")
      assert "setup has explicit public schema CREATE" (any (\grant -> privilege grant == SchemaCreate) (setupSchemaGrants config))
      assert "visible WAL_LOG default overridden" (Text.isInfixOf "FILE_COPY" (Settei.renderResolutionText (Settei.report resolved)))
      assert "secret redacted on success" (not (Text.isInfixOf "top-secret-credential" (Settei.renderResolutionText (Settei.report resolved))))
      assert "secret redacted in typed config" (not (isInfixOf "top-secret-credential" (show config)))
  let bad = Env.environmentSource validated (Env.envSnapshot [("HINAGATA_APPLICATION_PASSWORD", "bad\0password"), ("HINAGATA_ENDPOINT_PORT", "0")])
      failed = Settei.resolve Settei.defaultResolveOptions [low, bad] hinagataConfig
      errorText = either Settei.renderErrorsText (const "") (Settei.answer failed)
  assert "bad settings rejected" (either (const True) (const False) (Settei.answer failed))
  assert "secret redacted on failure" (not (Text.isInfixOf "bad\0password" (errorText <> Settei.renderResolutionText (Settei.report failed))))
  let defaults = Settei.resolve Settei.defaultResolveOptions [low] hinagataConfig
  assert "default strategy visible" (Text.isInfixOf "clone.strategy = WalLog" (Settei.renderResolutionText (Settei.report defaults)))
  assert "no database default permits mutation" (either (const True) (const False) (Settei.answer (Settei.resolve Settei.defaultResolveOptions [] hinagataConfig)))

sourceOrFail :: Text -> Settei.SourceKind -> [(Text, Text)] -> Settei.Source
sourceOrFail name kind values =
  case Settei.sourceFromPairs name kind [(settingKey, Settei.RawText value) | (rawKey, value) <- values, Right settingKey <- [Settei.parseKey rawKey]] of
    Right result -> result
    Left errors -> error (show errors)

bundleTests :: IO ()
bundleTests = withSystemTempDirectory "hinagata-core-test-" $ \workspace -> do
  let fixtureRoot = workspace </> "fixtures"
      bundleRoot = workspace </> "bundles"
      fixtureDirectory = fixtureRoot </> "example"
      sqlPath = fixtureDirectory </> "fixture.sql"
      config =
        Bundle.BundleConfig
          { Bundle.fixtureRoot = fixtureRoot,
            Bundle.bundleRoot = bundleRoot,
            Bundle.sqlSizeLimit = positive 1024,
            Bundle.chunkSize = positive 7
          }
  createDirectoryIfMissing True fixtureDirectory
  ByteString.writeFile sqlPath "SELECT 1;"
  first <- bundleOrFail =<< Bundle.compileFixtures config [fixtureName "example"]
  again <- bundleOrFail =<< Bundle.compileFixtures config [fixtureName "example"]
  assert "bundle digest deterministic" (Bundle.planDigest first == Bundle.planDigest again)
  assert "verified bundle reused" (Bundle.planDirectory first == Bundle.planDirectory again)
  let capturedPath = Bundle.planDirectory first </> "step-0"
  assert "bundle contains captured bytes" =<< ((== "SELECT 1;") <$> ByteString.readFile capturedPath)
  ByteString.writeFile capturedPath "corrupted"
  rebuilt <- bundleOrFail =<< Bundle.compileFixtures config [fixtureName "example"]
  assert "modified cache rebuilt" (Bundle.planDigest first == Bundle.planDigest rebuilt && Bundle.planDirectory first /= Bundle.planDirectory rebuilt)
  ByteString.writeFile sqlPath "SELECT 2;"
  changed <- bundleOrFail =<< Bundle.compileFixtures config [fixtureName "example"]
  assert "source bytes change digest" (Bundle.planDigest changed /= Bundle.planDigest first)
  assert "existing plan retains frozen bytes" =<< ((== "SELECT 1;") <$> ByteString.readFile (Bundle.planDirectory rebuilt </> "step-0"))
  ByteString.writeFile sqlPath "BEGIN;"
  invalidSql <- Bundle.compileFixtures config [fixtureName "example"]
  assert "invalid SQL rejected before plan publication" (case invalidSql of Left (Bundle.InvalidSql _ _) -> True; _ -> False)
  let outsideFile = workspace </> "outside.sql"
  ByteString.writeFile outsideFile "SELECT 3;"
  createFileLink outsideFile (fixtureDirectory </> "escape.sql")
  ByteString.writeFile (fixtureDirectory </> "fixture.yaml") "name: example\nsteps: [{sql: escape.sql}]\n"
  escaped <- Bundle.compileFixtures config [fixtureName "example"]
  assert "symlink escape rejected" (case escaped of Left (Bundle.UnsafePath _) -> True; _ -> False)
  let brokenDirectory = fixtureRoot </> "broken"
  createDirectoryIfMissing True brokenDirectory
  ByteString.writeFile (brokenDirectory </> "fixture.sql") "SELECT 1;"
  createFileLink (workspace </> "missing.yaml") (brokenDirectory </> "fixture.yaml")
  broken <- Bundle.compileFixtures config [fixtureName "broken"]
  assert "broken manifest symlink rejected" (case broken of Left (Bundle.UnsafePath _) -> True; _ -> False)
  let copyDirectory = fixtureRoot </> "members"
      copyManifest = copyDirectory </> "fixture.yaml"
      csvPath = copyDirectory </> "members.csv"
  createDirectoryIfMissing True copyDirectory
  ByteString.writeFile csvPath "id\n1\n"
  ByteString.writeFile copyManifest "name: members\nsteps:\n  - copy:\n      table: {schema: app, name: members}\n      columns: [id]\n      file: members.csv\n      format: csv\n      header: true\n"
  copyOne <- bundleOrFail =<< Bundle.compileFixtures config [fixtureName "members"]
  ByteString.writeFile copyManifest "name: members\nsteps:\n  - copy:\n      table: {schema: app, name: members}\n      columns: [id]\n      file: members.csv\n      format: csv\n      header: false\n"
  copyTwo <- bundleOrFail =<< Bundle.compileFixtures config [fixtureName "members"]
  assert "COPY option changes digest" (Bundle.planDigest copyOne /= Bundle.planDigest copyTwo)
  ByteString.writeFile csvPath "id\n2\n"
  copyThree <- bundleOrFail =<< Bundle.compileFixtures config [fixtureName "members"]
  assert "CSV bytes change digest" (Bundle.planDigest copyTwo /= Bundle.planDigest copyThree)
  let leftDirectory = fixtureRoot </> "left"
      rightDirectory = fixtureRoot </> "right"
      scenarioDirectory = fixtureRoot </> "scenario"
  mapM_ (createDirectoryIfMissing True) [leftDirectory, rightDirectory, scenarioDirectory]
  ByteString.writeFile (leftDirectory </> "fixture.sql") "SELECT 10;"
  ByteString.writeFile (rightDirectory </> "fixture.sql") "SELECT 20;"
  ByteString.writeFile (scenarioDirectory </> "fixture.sql") "SELECT 30;"
  ByteString.writeFile (scenarioDirectory </> "fixture.yaml") "name: scenario\ninclude: [left, right]\nsteps: [{sql: fixture.sql}]\n"
  orderOne <- bundleOrFail =<< Bundle.compileFixtures config [fixtureName "scenario"]
  ByteString.writeFile (scenarioDirectory </> "fixture.yaml") "name: scenario\ninclude: [right, left]\nsteps: [{sql: fixture.sql}]\n"
  orderTwo <- bundleOrFail =<< Bundle.compileFixtures config [fixtureName "scenario"]
  assert "include order changes digest" (Bundle.planDigest orderOne /= Bundle.planDigest orderTwo)
  base <- bundleOrFail =<< Bundle.compileFixtures config (map fixtureName ["members", "left", "right"])
  let composed = Bundle.composePlans base orderOne
  assert "base prefix retains unrelated fixtures" (case composed of Right result -> length (Bundle.basePrefix result) == 3 && length (Bundle.scenarioRemainder result) == 1; _ -> False)
  assert "COPY option conflict rejected" (Bundle.composePlans copyOne copyTwo == Left (Bundle.ConflictingFixture (fixtureName "members")))
  ByteString.writeFile (leftDirectory </> "fixture.sql") "SELECT 11;"
  changedShared <- bundleOrFail =<< Bundle.compileFixtures config [fixtureName "scenario"]
  assert "shared byte conflict rejected" (Bundle.composePlans base changedShared == Left (Bundle.ConflictingFixture (fixtureName "left")))
  ByteString.writeFile (leftDirectory </> "fixture.sql") "SELECT 10;"
  ByteString.writeFile (leftDirectory </> "fixture.yaml") "name: left\ninclude: [right]\nsteps: [{sql: fixture.sql}]\n"
  changedIncludes <- bundleOrFail =<< Bundle.compileFixtures config [fixtureName "scenario"]
  assert "shared dependency conflict rejected" (Bundle.composePlans base changedIncludes == Left (Bundle.ConflictingFixture (fixtureName "left")))

bundleOrFail :: Either Bundle.BundleError Bundle.FixturePlan -> IO Bundle.FixturePlan
bundleOrFail = either (fail . show) pure

positive :: Int -> Positive
positive value = either (error . show) id (mkPositive "test" value)

fixture :: Text -> [Text] -> FixtureDefinition
fixture fixtureNameValue includeNames =
  FixtureDefinition
    { name = fixtureName fixtureNameValue,
      includes = map fixtureName includeNames,
      steps = [SqlFile "fixture.sql"]
    }

fixtureName :: Text -> FixtureName
fixtureName value = either (error . show) id (mkFixtureName value)

assert :: String -> Bool -> IO ()
assert label success = unless success $ do
  putStrLn ("FAIL: " ++ label)
  exitFailure

sqlIdentifier :: Text -> SqlIdentifier
sqlIdentifier value = either (error . show) id (mkSqlIdentifier value)

isManifestError :: Either ManifestError a -> Bool
isManifestError (Left _) = True
isManifestError (Right _) = False

isSqlPolicyError :: Either SqlPolicyError () -> Bool
isSqlPolicyError (Left _) = True
isSqlPolicyError (Right ()) = False
