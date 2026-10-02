module Hinagata.Cli.Output
  ( CliError (..),
    bundleError,
    emitError,
    emitPlan,
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Json
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Hinagata.Fixture.Bundle
import Hinagata.Fixture.Types (fixtureNameText)
import System.IO qualified as IO

data CliError = CliError
  { phase :: !Text.Text,
    code :: !Text.Text,
    message :: !Text.Text,
    fixture :: !(Maybe Text.Text),
    exitCode :: !Int
  }
  deriving stock (Eq, Show)

bundleError :: BundleError -> CliError
bundleError problem = case problem of
  BundleIo reason -> failure "bundle_io" reason Nothing
  MissingFixture name -> failure "fixture_missing" "fixture does not exist" (Just (fixtureNameText name))
  UnsafePath path -> failure "fixture_unsafe_path" (Text.pack path) Nothing
  InvalidFixtureManifest name _ -> failure "fixture_manifest_invalid" "fixture manifest is invalid" (Just (fixtureNameText name))
  InvalidFixtureGraph _ -> failure "fixture_graph_invalid" "fixture graph is invalid" Nothing
  SourceChanged path -> failure "fixture_source_changed" (Text.pack path) Nothing
  SqlStepTooLarge path -> failure "fixture_sql_too_large" (Text.pack path) Nothing
  InvalidSql path _ -> failure "fixture_sql_invalid" (Text.pack path) Nothing
  where
    failure code message fixture = CliError "fixture-plan" code message fixture 1

emitError :: Bool -> CliError -> IO ()
emitError jsonSelected CliError {phase, code, message, fixture} = do
  TextIO.hPutStrLn IO.stderr (phase <> ": " <> code <> ": " <> message)
  if jsonSelected
    then
      Lazy.putStr
        ( Json.encode
            ( Json.object
                [ "formatVersion" .= (1 :: Int),
                  "ok" .= False,
                  "error"
                    .= Json.object
                      [ "phase" .= phase,
                        "code" .= code,
                        "message" .= message,
                        "fixture" .= fixture
                      ]
                ]
            )
            <> "\n"
        )
    else pure ()

emitPlan :: Bool -> FixturePlan -> IO ()
emitPlan jsonSelected plan =
  if jsonSelected
    then Lazy.putStr (Json.encode planValue <> "\n")
    else do
      TextIO.putStrLn ("plan " <> planDigest plan)
      mapM_ (TextIO.putStrLn . ("fixture " <>) . fixtureNameText . name) (planFixtures plan)
  where
    planValue =
      Json.object
        [ "formatVersion" .= (1 :: Int),
          "ok" .= True,
          "kind" .= ("fixture-plan" :: Text.Text),
          "digest" .= planDigest plan,
          "fixtures" .= map fixtureValue (planFixtures plan)
        ]

fixtureValue :: CapturedFixture -> Json.Value
fixtureValue CapturedFixture {name, includes, steps, identity} =
  Json.object
    [ "name" .= fixtureNameText name,
      "includes" .= map fixtureNameText includes,
      "identity" .= identity,
      "steps" .= map stepValue steps
    ]

stepValue :: CapturedStep -> Json.Value
stepValue CapturedSql {relativePath, contentDigest, byteLength} =
  Json.object ["type" .= ("sql" :: Text.Text), "path" .= relativePath, "digest" .= contentDigest, "bytes" .= byteLength]
stepValue CapturedCopy {relativePath, contentDigest, byteLength} =
  Json.object ["type" .= ("copy" :: Text.Text), "path" .= relativePath, "digest" .= contentDigest, "bytes" .= byteLength]
