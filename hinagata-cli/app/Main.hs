module Main (main) where

import Data.Text.IO qualified as TextIO
import Data.Version (showVersion)
import Hinagata.Cli.Config
import Hinagata.Cli.Options
import Hinagata.Cli.Output
import Hinagata.Config (AccessConfig (..), EndpointConfig (..), HinagataConfig (..), hinagataConfig)
import Hinagata.Connection (mkConnectionTarget)
import Hinagata.Fixture.Bundle
import Hinagata.Fixture.Types (mkFixtureName)
import Hinagata.Postgres.Load (loadInto)
import Hinagata.Postgres.Session (SessionOptions (..), defaultSessionOptions)
import Hinagata.Prelude ()
import Hinagata.Types (mkDatabaseName, positiveValue)
import Options.Applicative qualified as Options
import Options.Applicative.BashCompletion qualified as Completion
import Paths_hinagata_cli qualified as Package
import Settei qualified
import Settei.Optparse qualified as SetteiOptions
import System.Environment (getProgName)
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)

main :: IO ()
main = do
  options <- Options.execParser (parserInfo ("hinagata " <> showVersion Package.version <> " (revision unavailable)"))
  case command options of
    Just (Completions shell) -> do
      name <- getProgName
      putStr (completionScript shell name)
    _ -> case SetteiOptions.schemaDiagnostic (diagnosticMode options) (Settei.describe hinagataConfig) of
      Just output -> TextIO.putStr output
      Nothing -> do
        resolved <- resolveConfig options
        case resolved of
          Left failure -> reportConfigFailure options failure
          Right (configuration, result) -> do
            TextIO.hPutStr stderr (Settei.renderWarningsText (Settei.warnings result))
            case SetteiOptions.resolutionDiagnostic (diagnosticMode options) result of
              Just output -> TextIO.putStr output
              Nothing -> dispatch configuration options

dispatch :: HinagataConfig -> CliOptions -> IO ()
dispatch configuration@HinagataConfig {fixtureRoot, bundleRoot, sqlSizeLimit, chunkSize} options = case command options of
  Just (FixturePlan roots jsonSelected) ->
    case traverse mkFixtureName roots of
      Left problem -> abort jsonSelected (CliError "options" "fixture_name_invalid" problem Nothing Nothing Nothing Nothing 2)
      Right names -> do
        let bundle = BundleConfig fixtureRoot bundleRoot sqlSizeLimit chunkSize
        compiled <- compileFixtures bundle names
        case compiled of
          Left problem -> abort jsonSelected (bundleError problem)
          Right plan -> emitPlan jsonSelected plan
  Just (FixtureLoad roots databaseText jsonSelected) ->
    case (traverse mkFixtureName roots, mkDatabaseName databaseText) of
      (Left problem, _) -> abort jsonSelected (CliError "options" "fixture_name_invalid" problem Nothing Nothing Nothing Nothing 2)
      (_, Left problem) -> abort jsonSelected (CliError "options" "target_database_invalid" problem Nothing Nothing Nothing Nothing 2)
      (Right names, Right database) -> do
        let bundle = BundleConfig fixtureRoot bundleRoot sqlSizeLimit chunkSize
        compiled <- compileFixtures bundle names
        case compiled of
          Left problem -> abort jsonSelected (bundleError problem)
          Right plan -> do
            let EndpointConfig {host = serverHost, port = serverPort} = endpoint configuration
                AccessConfig {user = roleUser, password = rolePassword} = setup configuration
                sessionOptions = defaultSessionOptions {operationDeadlineMs = positiveValue (setupDeadlineMs configuration), statementDeadlineMs = positiveValue (setupDeadlineMs configuration)}
            case mkConnectionTarget serverHost serverPort roleUser database rolePassword of
              Left problem -> abort jsonSelected (CliError "options" "target_invalid" problem Nothing Nothing Nothing Nothing 2)
              Right target -> do
                loaded <- loadInto target sessionOptions plan
                case loaded of
                  Left problem -> abort jsonSelected (loadError problem)
                  Right report -> emitLoad jsonSelected database report
  Nothing -> abort False (CliError "options" "command_required" "choose a command or configuration diagnostic" Nothing Nothing Nothing Nothing 2)
  Just (Completions _) -> pure ()

reportConfigFailure :: CliOptions -> ConfigFailure -> IO ()
reportConfigFailure options failure = do
  let jsonSelected = case command options of Just (FixturePlan _ selected) -> selected; Just (FixtureLoad _ _ selected) -> selected; _ -> False
      outcome = case failure of
        SourceFailure message -> CliError "configuration-source" "config_source_invalid" message Nothing Nothing Nothing Nothing 3
        ResolutionFailure message _ -> CliError "configuration-resolution" "config_resolution_invalid" message Nothing Nothing Nothing Nothing 4
  case failure of
    ResolutionFailure _ explanation -> TextIO.hPutStr stderr explanation
    _ -> pure ()
  abort jsonSelected outcome

abort :: Bool -> CliError -> IO a
abort jsonSelected failure = do
  emitError jsonSelected failure
  exitWith (ExitFailure (exitCode failure))

completionScript :: Shell -> String -> String
completionScript shell name = case shell of
  Bash -> Completion.bashCompletionScript name name
  Zsh -> Completion.zshCompletionScript name name
  Fish -> Completion.fishCompletionScript name name
