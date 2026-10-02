-- | CLI assembly of frozen plans and executable hooks; SQL stays in the library.
module Hinagata.Cli.Command
  ( prepareBaseline,
    compileScenario,
  )
where

import Control.Exception (IOException, try)
import Data.Text qualified as Text
import Hinagata.Cli.Config (CliSettings (..), HookSettings (..))
import Hinagata.Cli.Output (CliError (..), bundleError)
import Hinagata.Cli.Process (ChildFailure (..), ChildReport (..), ChildSpec (..), parseOverlay, runChild)
import Hinagata.Config (HinagataConfig (..))
import Hinagata.Connection (ConnectionTarget)
import Hinagata.Fixture.Bundle (BundleConfig (..), FixturePlan, compileFixtures)
import Hinagata.Fixture.Types (mkFixtureName)
import Hinagata.Postgres.Baseline (BaselineError (..), BaselineRef, BaselineSpec (..), PreparationReport, ensureBaseline)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute)

prepareBaseline :: HinagataConfig -> CliSettings -> IO (Either CliError (BaselineRef, PreparationReport))
prepareBaseline configuration settings = do
  case (hookRunner "migration" (migration settings), hookRunner "verification" (verification settings)) of
    (Left problem, _) -> pure (Left problem)
    (_, Left problem) -> pure (Left problem)
    (Right migrationHook, Right verificationHook) -> do
      compiled <- compileScenario configuration (baseFixtures settings)
      case compiled of
        Left problem -> pure (Left problem)
        Right basePlan -> do
          let specification =
                BaselineSpec
                  { configuration,
                    basePlan,
                    migrationRevision = revision (migration settings),
                    verificationRevision = revision (verification settings),
                    requiredExtensions = [],
                    requiredLocale = Nothing,
                    migrationHook,
                    verificationHook,
                    clonePreparationHook = Nothing,
                    compareAgainst = Nothing
                  }
          prepared <- ensureBaseline specification
          pure $ case prepared of
            Left BaselineError {cause, sqlState} -> Left (CliError "baseline-prepare" "baseline_failed" cause Nothing Nothing sqlState Nothing 1)
            Right value -> Right value

compileScenario :: HinagataConfig -> [Text.Text] -> IO (Either CliError FixturePlan)
compileScenario HinagataConfig {fixtureRoot, bundleRoot, sqlSizeLimit, chunkSize} roots =
  case traverse mkFixtureName roots of
    Left problem -> pure (Left (CliError "options" "fixture_name_invalid" problem Nothing Nothing Nothing Nothing 2))
    Right names -> do
      compiled <- compileFixtures (BundleConfig fixtureRoot bundleRoot sqlSizeLimit chunkSize) names
      pure (either (Left . bundleError) Right compiled)

hookRunner :: Text.Text -> HookSettings -> Either CliError (ConnectionTarget -> IO (Either Text.Text ()))
hookRunner name HookSettings {executable, arguments, workingDirectory, environment, revision, deadlineMs} =
  case (executable, parseOverlay environment) of
    (Nothing, _)
      | null arguments && workingDirectory == Nothing && null environment && revision == Nothing -> Right (\_ -> pure (Right ()))
      | otherwise -> Left (invalid "hook settings require an executable")
    (_, Left problem) -> Left (invalid problem)
    (Just program, Right overlay)
      | Text.null program || Text.any (== '\0') program -> Left (invalid "hook executable is empty or contains NUL")
      | any (Text.any (== '\0')) arguments -> Left (invalid "hook argv contains NUL")
      | maybe False (not . isAbsolute . Text.unpack) workingDirectory -> Left (invalid "hook cwd must be absolute")
      | otherwise -> Right $ \target -> do
          attempted <-
            try @IOException $
              runChild
                ChildSpec
                  { executable = Text.unpack program,
                    arguments = map Text.unpack arguments,
                    workingDirectory = Text.unpack <$> workingDirectory,
                    environment = overlay,
                    target,
                    identifiers = Nothing,
                    deadlineMs = Just deadlineMs,
                    stdoutToStderr = True
                  }
          pure $ case attempted of
            Left _ -> Left (name <> " hook could not run")
            Right result -> case result of
              Left ChildSpawnFailed -> Left (name <> " hook could not be started")
              Left ChildIdentityUnavailable -> Left (name <> " hook process identity was unavailable")
              Right ChildReport {cleanupFailure = Just problem} -> Left (name <> " hook cleanup failed: " <> problem)
              Right ChildReport {timedOut = True} -> Left (name <> " hook timed out")
              Right ChildReport {childExit = Just ExitSuccess} -> Right ()
              Right ChildReport {childExit = Just (ExitFailure status)} -> Left (name <> " hook exited with status " <> Text.pack (show status))
              Right _ -> Left (name <> " hook did not report an exit status")
  where
    invalid message = CliError "configuration-resolution" "hook_invalid" (name <> ": " <> message) Nothing Nothing Nothing Nothing 4
