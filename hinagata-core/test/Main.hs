module Main (main) where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Hinagata.Connection
import Hinagata.Fixture.Graph
import Hinagata.Fixture.Types
import Hinagata.Prelude
import Hinagata.Types
import System.Exit (exitFailure)

main :: IO ()
main = do
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
