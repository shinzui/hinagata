{-# LANGUAGE CPP #-}

module Main (main) where

import Control.Exception (IOException, catch, try)
import Data.List (sort)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Version (showVersion)
import Hinagata.Cli.Command (compileScenario, prepareBaseline)
import Hinagata.Cli.Config
import Hinagata.Cli.Options
import Hinagata.Cli.Output
import Hinagata.Cli.Process (CancellationScope, ChildCleanupException (..), ChildFailure (..), ChildReport (..), ChildSpec (..), CommandCancelled (..), cancellationSignal, checkCancellation, runChild, withCancellationScope, withCommandCancellation)
import Hinagata.Cli.Validation (cancelledError, validateBatches)
import Hinagata.Config (AccessConfig (..), EndpointConfig (..), HinagataConfig (..))
import Hinagata.Connection (mkConnectionTarget)
import Hinagata.Fixture.Bundle
import Hinagata.Fixture.Types (mkFixtureName)
import Hinagata.Postgres.Cleanup (CleanupResult (..), CleanupSelection (..), applyCleanup, inspectLease, planCleanup, releaseLease)
import Hinagata.Postgres.Lease (LeaseError (..), LeaseInfo (..), LeaseOutcome (..), RetentionPolicy (..))
import Hinagata.Postgres.Load (loadInto)
import Hinagata.Postgres.Manager (withManagedDatabaseClassified, withManager)
import Hinagata.Postgres.Session (SessionOptions (..), defaultSessionOptions)
import Hinagata.Prelude ()
import Hinagata.Types (mkDatabaseName, positiveValue)
import Options.Applicative qualified as Options
import Options.Applicative.BashCompletion qualified as Completion
import Paths_hinagata_cli qualified as Package
import Settei qualified
import Settei.Optparse qualified as SetteiOptions
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (getProgName)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (stderr)

main :: IO ()
main = do
  options <- Options.execParser (parserInfo ("hinagata " <> showVersion Package.version <> " (" <> buildRevision <> ")"))
  withCancellationScope $ \scope -> do
    completed <- try @ExitCode (withCommandCancellation scope (resolveAndDispatch scope options) `catch` \(CommandCancelled signal) -> abort (jsonOutput options) (cancelledError signal))
    signal <- cancellationSignal scope
    case signal of
      Just number -> exitWith (ExitFailure (128 + number))
      Nothing -> either exitWith pure completed

resolveAndDispatch :: CancellationScope -> CliOptions -> IO ()
resolveAndDispatch scope options =
  case command options of
    Just (Completions shell) -> do
      name <- getProgName
      putStr (completionScript shell name)
    _ -> case SetteiOptions.schemaDiagnostic (diagnosticMode options) (Settei.describe cliConfiguration) of
      Just output -> TextIO.putStr output
      Nothing -> do
        resolved <- resolveConfig options
        case resolved of
          Left failure -> reportConfigFailure options failure
          Right ((configuration, settings), result) -> do
            TextIO.hPutStr stderr (Settei.renderWarningsText (Settei.warnings result))
            case SetteiOptions.resolutionDiagnostic (diagnosticMode options) result of
              Just output -> TextIO.putStr output
              Nothing -> dispatch scope configuration settings options

dispatch :: CancellationScope -> HinagataConfig -> CliSettings -> CliOptions -> IO ()
dispatch scope configuration@HinagataConfig {fixtureRoot, bundleRoot, sqlSizeLimit, chunkSize} settings options = case command options of
  Just (FixturePlan roots jsonSelected) ->
    case traverse mkFixtureName roots of
      Left problem -> abort jsonSelected (CliError "options" "fixture_name_invalid" problem Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
      Right names -> do
        let bundle = BundleConfig fixtureRoot bundleRoot sqlSizeLimit chunkSize
        compiled <- compileFixtures bundle names
        case compiled of
          Left problem -> abort jsonSelected (bundleError problem)
          Right plan -> checkCancellation scope >> emitPlan jsonSelected plan
  Just (FixtureLoad roots databaseText jsonSelected) ->
    case (traverse mkFixtureName roots, mkDatabaseName databaseText) of
      (Left problem, _) -> abort jsonSelected (CliError "options" "fixture_name_invalid" problem Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
      (_, Left problem) -> abort jsonSelected (CliError "options" "target_database_invalid" problem Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
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
              Left problem -> abort jsonSelected (CliError "options" "target_invalid" problem Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
              Right target -> do
                loaded <- loadInto target sessionOptions plan
                case loaded of
                  Left problem -> abort jsonSelected (loadError problem)
                  Right report -> checkCancellation scope >> emitLoad jsonSelected database report
  Just (FixtureValidate roots allSelected jsonSelected)
    | allSelected && not (null roots) -> abort jsonSelected (CliError "options" "validate_selection_invalid" "choose names or --all" Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
    | not allSelected && null roots -> abort jsonSelected (CliError "options" "validate_selection_required" "choose scenario names or --all" Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
    | otherwise -> do
        selected <- if allSelected then discoverScenarios fixtureRoot else pure roots
        if null selected
          then abort jsonSelected (CliError "options" "validate_selection_empty" "no scenario fixtures were found" Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
          else do
            prepared <- prepareBaseline scope configuration settings
            case prepared of
              Left problem -> abort jsonSelected problem
              Right (baseline, _) -> do
                let workerCount = max 1 (min (positiveValue (setupWorkers configuration)) (positiveValue (activeLeases configuration)))
                    validate manager name = do
                      checkCancellation scope
                      compiled <- compileScenario configuration [name]
                      case compiled of
                        Left problem -> pure (ValidationResult name (Left problem))
                        Right scenarioPlan -> do
                          completed <- withManagedDatabaseClassified manager baseline scenarioPlan ReleaseAlways (const False) (const (checkCancellation scope))
                          pure $ ValidationResult name $ case completed of
                            Left problem -> Left (leaseError "fixture-validate" (Just name) problem)
                            Right LeaseOutcome {cleanupDiagnostic = Just LeaseError {cause, sqlState}} -> Left (CliError "fixture-validate" "cleanup_failed" cause (Just name) Nothing sqlState Nothing 1 Nothing Nothing Nothing Nothing)
                            Right LeaseOutcome {timings} -> Right timings
                results <- withManager configuration $ \manager ->
                  validateBatches scope workerCount (validate manager) selected
                let failed = any (\ValidationResult {result} -> either (const True) (const False) result) results
                if failed then pure () else checkCancellation scope
                emitValidation jsonSelected results
                if failed then exitWith (ExitFailure 1) else pure ()
  Just (DbPrepare jsonSelected) -> do
    prepared <- prepareBaseline scope configuration settings
    either (abort jsonSelected) (\(_, report) -> checkCancellation scope >> emitPreparation jsonSelected report) prepared
  Just (DbAcquire roots jsonSelected) -> do
    scenario <- compileScenario configuration roots
    case scenario of
      Left problem -> abort jsonSelected problem
      Right scenarioPlan -> do
        prepared <- prepareBaseline scope configuration settings
        case prepared of
          Left problem -> abort jsonSelected problem
          Right (baseline, _) -> do
            acquired <- withManager configuration $ \manager ->
              withManagedDatabaseClassified manager baseline scenarioPlan DetachAlways (const False) (\info -> checkCancellation scope >> pure info)
            case acquired of
              Left problem -> abort jsonSelected (leaseError "lease-acquire" Nothing problem)
              Right LeaseOutcome {cleanupDiagnostic = Just LeaseError {cause, sqlState}} ->
                abort jsonSelected (CliError "lease-acquire" "lease_cleanup_failed" cause Nothing Nothing sqlState Nothing 1 Nothing Nothing Nothing Nothing)
              Right LeaseOutcome {leaseInfo, timings} -> checkCancellation scope >> emitAcquisition jsonSelected leaseInfo timings
  Just (DbWith _ _ jsonSelected []) -> abort jsonSelected (CliError "options" "program_required" "db with requires a program after --" Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
  Just (DbWith roots preserveOnFailure jsonSelected (program : programArguments)) -> do
    scenario <- compileScenario configuration roots
    case scenario of
      Left problem -> abort jsonSelected problem
      Right scenarioPlan -> do
        prepared <- prepareBaseline scope configuration settings
        case prepared of
          Left problem -> abort jsonSelected problem
          Right (baseline, _) -> do
            let policy = PreserveFailures
                classify result = case result of
                  Left ChildIdentityUnavailable -> True
                  Left ChildSpawnFailed -> preserveOnFailure
                  Right ChildReport {cleanupFailure = Just _} -> True
                  Right ChildReport {childExit = Just ExitSuccess, timedOut = False, cancelledBy = Nothing} -> False
                  Right _ -> preserveOnFailure
                run LeaseInfo {leaseId, runId, applicationTarget} = do
                  checkCancellation scope
                  let child =
                        ChildSpec
                          { executable = program,
                            arguments = programArguments,
                            workingDirectory = Nothing,
                            environment = [],
                            target = applicationTarget,
                            identifiers = Just (runId, leaseId),
                            deadlineMs = Nothing,
                            stdoutToStderr = jsonSelected
                          }
                  started <-
                    try @IOException
                      ( runChild scope child `catch` \ChildCleanupException -> do
                          signal <- cancellationSignal scope
                          pure (Right (ChildReport Nothing False signal (Just "child process cleanup uncertain")))
                      )
                  pure (either (const (Left ChildSpawnFailed)) id started)
            completed <- withManager configuration $ \manager ->
              withManagedDatabaseClassified manager baseline scenarioPlan policy classify run
            case completed of
              Left problem -> abort jsonSelected (leaseError "lease-acquire" Nothing problem)
              Right outcome -> do
                let status = withExitCode outcome
                if status == 0 then checkCancellation scope else pure ()
                emitWith jsonSelected outcome
                if status == 0 then pure () else exitWith (ExitFailure status)
  Just (Inspect identifier jsonSelected) -> do
    inspected <- inspectLease configuration identifier
    either (abort jsonSelected . cleanupError) (emitCandidate jsonSelected) inspected
  Just (DbRelease identifier jsonSelected) -> do
    released <- releaseLease configuration identifier
    case released of
      Left problem -> abort jsonSelected (cleanupError problem)
      Right outcome -> do
        emitCleanupResults jsonSelected [outcome]
        case outcome of
          Refused _ _ -> exitWith (ExitFailure 1)
          Skipped _ _ -> exitWith (ExitFailure 1)
          _ -> pure ()
  Just (Clean apply includeRetained identifiers jsonSelected)
    | not apply && (includeRetained || not (null identifiers)) ->
        abort jsonSelected (CliError "options" "clean_preview_options_invalid" "--id and --include-retained require --apply" Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
    | apply && null identifiers ->
        abort jsonSelected (CliError "options" "clean_selection_required" "--apply requires one or more --id selections" Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
    | includeRetained && null identifiers ->
        abort jsonSelected (CliError "options" "clean_retained_selection_required" "retained cleanup requires selected allocation IDs" Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
    | apply -> do
        let selection = if includeRetained then IncludeRetained else OrphansOnly
        applied <- applyCleanup configuration selection identifiers
        case applied of
          Left problem -> abort jsonSelected (cleanupError problem)
          Right outcomes -> do
            emitCleanupResults jsonSelected outcomes
            if any unsuccessful outcomes then exitWith (ExitFailure 1) else pure ()
    | otherwise -> do
        planned <- planCleanup configuration
        either (abort jsonSelected . cleanupError) (emitCleanupPlan jsonSelected) planned
  Nothing -> abort False (CliError "options" "command_required" "choose a command or configuration diagnostic" Nothing Nothing Nothing Nothing 2 Nothing Nothing Nothing Nothing)
  Just (Completions _) -> pure ()
  where
    unsuccessful (Refused _ _) = True
    unsuccessful (Skipped _ _) = True
    unsuccessful _ = False

reportConfigFailure :: CliOptions -> ConfigFailure -> IO ()
reportConfigFailure options failure = do
  let jsonSelected = jsonOutput options
      outcome = case failure of
        SourceFailure message -> CliError "configuration-source" "config_source_invalid" message Nothing Nothing Nothing Nothing 3 Nothing Nothing Nothing Nothing
        ResolutionFailure message _ -> CliError "configuration-resolution" "config_resolution_invalid" message Nothing Nothing Nothing Nothing 4 Nothing Nothing Nothing Nothing
  case failure of
    ResolutionFailure _ explanation -> TextIO.hPutStr stderr explanation
    _ -> pure ()
  abort jsonSelected outcome

jsonOutput :: CliOptions -> Bool
jsonOutput options = case command options of
  Just (FixturePlan _ selected) -> selected
  Just (FixtureLoad _ _ selected) -> selected
  Just (FixtureValidate _ _ selected) -> selected
  Just (DbPrepare selected) -> selected
  Just (DbAcquire _ selected) -> selected
  Just (DbWith _ _ selected _) -> selected
  Just (DbRelease _ selected) -> selected
  Just (Inspect _ selected) -> selected
  Just (Clean _ _ _ selected) -> selected
  _ -> False

abort :: Bool -> CliError -> IO a
abort jsonSelected failure = do
  emitError jsonSelected failure
  exitWith (ExitFailure (exitCode failure))

completionScript :: Shell -> String -> String
completionScript shell name = case shell of
  Bash -> Completion.bashCompletionScript name name
  Zsh -> Completion.zshCompletionScript name name
  Fish -> Completion.fishCompletionScript name name

discoverScenarios :: FilePath -> IO [Text.Text]
discoverScenarios root = do
  directoryExists <- doesDirectoryExist root
  if not directoryExists
    then pure []
    else do
      entries <- sort <$> listDirectory root
      included <- traverse hasFixture entries
      pure [Text.pack entry | (entry, True) <- zip entries included]
  where
    hasFixture entry = do
      let directory = root </> entry
      validDirectory <- doesDirectoryExist directory
      if not validDirectory
        then pure False
        else do
          yaml <- doesFileExist (directory </> "fixture.yaml")
          sql <- doesFileExist (directory </> "fixture.sql")
          pure (yaml || sql)

buildRevision :: String
#ifdef GIT_HASH
buildRevision = "revision " <> GIT_HASH
#else
buildRevision = "revision unavailable"
#endif
