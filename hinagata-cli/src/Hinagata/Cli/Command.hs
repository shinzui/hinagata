-- | CLI assembly of frozen plans and executable hooks; SQL stays in the library.
module Hinagata.Cli.Command
  ( prepareBaseline,
    compileScenario,
    prepareBaselineWithRunner,
  )
where

import Control.Exception (Handler (..), IOException, catches, mask_, throwIO, try)
import Data.Text qualified as Text
import Hinagata.Cli.Config (CliSettings (..), HookSettings (..))
import Hinagata.Cli.Output (CliError (..), bundleError)
import Hinagata.Cli.Process (CancellationScope, ChildCleanupException (..), ChildFailure (..), ChildReport (..), ChildSpec (..), CommandCancelled (..), checkCancellation, parseOverlay, runChild)
import Hinagata.Config (HinagataConfig (..))
import Hinagata.Connection (ConnectionTarget)
import Hinagata.Fixture.Bundle (BundleConfig (..), FixturePlan, compileFixtures)
import Hinagata.Fixture.Types (mkFixtureName)
import Hinagata.Postgres.Baseline (BaselineError (..), BaselineRef, BaselineSpec (..), PreparationReport, ensureBaseline)
import Hinagata.Postgres.Lease (PreparationFailure (..), PreparationFailureKind (..))
import System.Exit (ExitCode (..))

prepareBaseline :: CancellationScope -> HinagataConfig -> CliSettings -> IO (Either CliError (BaselineRef, PreparationReport))
prepareBaseline = prepareBaselineWithRunner runChild

-- | Internal runner injection for exercising supervision failure at the actual
-- library/CLI boundary without a public configuration bypass.
prepareBaselineWithRunner :: (CancellationScope -> ChildSpec -> IO (Either ChildFailure ChildReport)) -> CancellationScope -> HinagataConfig -> CliSettings -> IO (Either CliError (BaselineRef, PreparationReport))
prepareBaselineWithRunner runner scope configuration settings = do
  checkCancellation scope
  let migrationHook = hookRunner runner scope "migration" False (migration settings)
      verificationHook = hookRunner runner scope "verification" False (verification settings)
      clonePreparationHook = case clonePreparation settings of
        HookSettings {executable = Nothing} -> Nothing
        _ -> Just (hookRunner runner scope "clone preparation" True (clonePreparation settings))
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
                clonePreparationHook,
                compareAgainst = Nothing
              }
      prepared <- ensureBaseline specification
      pure $ case prepared of
        Left BaselineError {cause, sqlState} -> Left (CliError "baseline-prepare" "baseline_failed" cause Nothing Nothing sqlState Nothing 1 Nothing Nothing)
        Right value -> Right value

compileScenario :: HinagataConfig -> [Text.Text] -> IO (Either CliError FixturePlan)
compileScenario HinagataConfig {fixtureRoot, bundleRoot, sqlSizeLimit, chunkSize} roots =
  case traverse mkFixtureName roots of
    Left problem -> pure (Left (CliError "options" "fixture_name_invalid" problem Nothing Nothing Nothing Nothing 2 Nothing Nothing))
    Right names -> do
      compiled <- compileFixtures (BundleConfig fixtureRoot bundleRoot sqlSizeLimit chunkSize) names
      pure (either (Left . bundleError) Right compiled)

-- Keep the supervision outcome and its release-safety classification masked
-- together. Blocking process waits remain interruptible.
hookRunner :: (CancellationScope -> ChildSpec -> IO (Either ChildFailure ChildReport)) -> CancellationScope -> Text.Text -> Bool -> HookSettings -> ConnectionTarget -> IO (Either Text.Text ())
hookRunner runner scope name preparation HookSettings {executable, arguments, workingDirectory, environment, deadlineMs} target = mask_ $ case executable of
  Nothing -> pure (Right ())
  Just program -> do
    let failWith kind safe =
          if preparation then throwIO (PreparationFailure kind safe) else pure (Left (name <> " hook failed: " <> Text.pack (show kind)))
        run = case parseOverlay environment of
          Left _ -> failWith PreparationSpawnFailed True
          Right overlay -> do
            attempted <-
              try @IOException $
                runner
                  scope
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
            case attempted of
              Left _ -> failWith PreparationSpawnFailed True
              Right result -> case result of
                Left ChildSpawnFailed -> failWith PreparationSpawnFailed True
                Left ChildIdentityUnavailable -> failWith PreparationIdentityUnavailable False
                Right ChildReport {cleanupFailure = Just _, cancelledBy = Just signal} -> failWith (PreparationCancelled signal) False
                Right ChildReport {cleanupFailure = Just _, timedOut = True} -> failWith PreparationTimeout False
                Right ChildReport {cleanupFailure = Just _, childExit = Just (ExitFailure status)} -> failWith (PreparationExit status) False
                Right ChildReport {cleanupFailure = Just _} -> failWith PreparationCleanupFailed False
                Right ChildReport {cancelledBy = Just signal} -> failWith (PreparationCancelled signal) True
                Right ChildReport {timedOut = True} -> failWith PreparationTimeout True
                Right ChildReport {childExit = Just ExitSuccess} -> checkCancellation scope >> pure (Right ())
                Right ChildReport {childExit = Just (ExitFailure status)} -> failWith (PreparationExit status) True
                Right _ -> failWith PreparationSpawnFailed True
    run
      `catches` [ Handler (\ChildCleanupException -> failWith PreparationCleanupFailed False),
                  Handler (\(CommandCancelled signal) -> failWith (PreparationCancelled signal) True)
                ]
