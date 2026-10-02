module Main (main) where

import Data.Text.IO qualified as TextIO
import Data.Version (showVersion)
import Hinagata.Cli.Config
import Hinagata.Cli.Options
import Hinagata.Cli.Output
import Hinagata.Config (HinagataConfig (..), hinagataConfig)
import Hinagata.Fixture.Bundle
import Hinagata.Fixture.Types (mkFixtureName)
import Hinagata.Prelude ()
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
dispatch HinagataConfig {fixtureRoot, bundleRoot, sqlSizeLimit, chunkSize} options = case command options of
  Just (FixturePlan roots jsonSelected) ->
    case traverse mkFixtureName roots of
      Left problem -> abort jsonSelected (CliError "options" "fixture_name_invalid" problem Nothing 2)
      Right names -> do
        let bundle = BundleConfig fixtureRoot bundleRoot sqlSizeLimit chunkSize
        compiled <- compileFixtures bundle names
        case compiled of
          Left problem -> abort jsonSelected (bundleError problem)
          Right plan -> emitPlan jsonSelected plan
  Nothing -> abort False (CliError "options" "command_required" "choose a command or configuration diagnostic" Nothing 2)
  Just (Completions _) -> pure ()

reportConfigFailure :: CliOptions -> ConfigFailure -> IO ()
reportConfigFailure options failure = do
  let jsonSelected = case command options of Just (FixturePlan _ selected) -> selected; _ -> False
      outcome = case failure of
        SourceFailure message -> CliError "configuration-source" "config_source_invalid" message Nothing 3
        ResolutionFailure message _ -> CliError "configuration-resolution" "config_resolution_invalid" message Nothing 4
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
