module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar
import Control.Exception (bracket, try)
import Control.Monad (unless, void)
import Data.IORef
import Hinagata.Cli.Command (compileScenario, prepareBaselineWithRunner)
import Hinagata.Cli.Config
import Hinagata.Cli.Options (CliOptions (..))
import Hinagata.Cli.Output (CliError (..), ValidationResult (..), leaseError)
import Hinagata.Cli.Process
import Hinagata.Cli.Process qualified as Process
import Hinagata.Cli.Validation (validateBatches)
import Hinagata.Config qualified as Config
import Hinagata.Connection
import Hinagata.Postgres.Cleanup qualified as Cleanup
import Hinagata.Postgres.Lease qualified as Lease
import Hinagata.Postgres.Manager
import Hinagata.Types
import Settei.Optparse (DiagnosticMode (NoDiagnostic))
import System.Directory (doesFileExist, removePathForcibly)
import System.Environment (getArgs)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Signals
import System.Posix.Temp (mkdtemp)
import System.Timeout (timeout)

main :: IO ()
main = bracket (mkdtemp "/tmp/hinagata-process-XXXXXX") removePathForcibly $ \directory -> do
  host <- require (tcpHost "127.0.0.1")
  port <- require (mkPort 1)
  database <- require (mkDatabaseName "unused")
  secret <- require (mkSecret "process-secret-sentinel")
  target <- require (mkConnectionTarget host port "unused" database (Just secret))
  let spec = ChildSpec "/bin/sh" [] Nothing [] target Nothing (Just 50) True
  -- Signals arriving before and during registration are observed atomically.
  restored <- newEmptyMVar
  previous <- installHandler sigTERM (Catch (void (tryPutMVar restored ()))) Nothing
  withCancellationScope $ \scope -> do
    withRegistration scope $ \marker -> do
      raiseSignal sigINT
      assert "registered child observes INT" =<< ((== Just 2) <$> timeout 1000000 (readMVar marker))
    withRegistration scope $ \marker ->
      assert "late registration observes prior cancellation" =<< ((== 2) <$> readMVar marker)
    raiseSignal sigTERM
    threadDelay 30000
    assert "first signal survives repeated signals" =<< ((== Just 2) <$> cancellationSignal scope)
    spawned <- try @CommandCancelled (runChild scope spec)
    assert "cancelled scope refuses spawning" (case spawned of Left (CommandCancelled 2) -> True; _ -> False)
  raiseSignal sigTERM
  assert "original handlers restored at scope exit" =<< ((== Just ()) <$> timeout 1000000 (takeMVar restored))
  _ <- installHandler sigTERM previous Nothing
  let marker = directory </> "password-path"
      asleep = spec {Process.arguments = ["-c", "printf '%s' \"$PGPASSFILE\" > \"$1\"; sleep 30", "sh", marker], Process.deadlineMs = Just 100}
  withCancellationScope $ \scope -> do
    report <- runChildWithCleanupCheck (pure False) scope asleep
    assert "deterministic uncertain stop retained in normal report" (case report of Right ChildReport {cleanupFailure = Just _, timedOut = True} -> True; _ -> False)
    password <- readFile marker
    assert "private password removed after timeout" . not =<< doesFileExist password
    unwound <- try @ChildCleanupException (timeout 150000 (runChildWithCleanupCheck (pure False) scope (asleep {Process.deadlineMs = Nothing})))
    assert "uncertain cleanup survives asynchronous timeout unwinding" (case unwound of Left ChildCleanupException -> True; _ -> False)
    passwordAfter <- readFile marker
    assert "private password removed during unwind" . not =<< doesFileExist passwordAfter
  withCancellationScope $ \scope -> do
    let ready = directory </> "ready"
        zeroExit = spec {Process.arguments = ["-c", "trap 'exit 0' INT TERM; touch \"$1\"; while :; do sleep .05; done", "sh", ready], Process.deadlineMs = Nothing}
    Async.withAsync (runChild scope zeroExit) $ \child -> do
      waitFile ready
      raiseSignal sigTERM
      result <- timeout 6000000 (Async.wait child)
      assert "zero-exit signal handler cannot turn cancellation into success" (case result of Just (Right ChildReport {cancelledBy = Just 15, cleanupFailure = Nothing}) -> True; _ -> False)
  getArgs >>= \case
    [] -> pure ()
    [path] -> postgresTests path
    _ -> fail "expected optional CLI configuration path"
  putStrLn "CLI process scope, race, and cleanup fault tests passed"

postgresTests :: FilePath -> IO ()
postgresTests path = do
  resolved <- resolveConfig (CliOptions [path] [] NoDiagnostic Nothing)
  ((configuration, settings), _) <- either (const (fail "test configuration failed")) pure resolved
  scenario <- require =<< compileScenario configuration []
  -- Both ordinary completion and outer-deadline unwinding must reach the same
  -- typed library preservation boundary, without calling the consumer.
  mapM_ (preservation configuration settings scenario) [False, True]
  withCancellationScope $ \scope -> do
    ordinal <- newIORef (0 :: Int)
    ready <- newEmptyMVar
    let runner commandScope child = do
          index <- atomicModifyIORef' ordinal (\n -> (n + 1, n))
          void (tryPutMVar ready ())
          if index == 0
            then runChildWithCleanupCheck (pure False) commandScope child
            else pure (Right (ChildReport (Just (ExitFailure 17)) False Nothing Nothing))
        hook = HookSettings (Just "/bin/sh") ["-c", "sleep 30"] Nothing [] Nothing 10000
        selected = settings {clonePreparation = hook}
    (baseline, _) <- require =<< prepareBaselineWithRunner runner scope configuration selected
    Async.withAsync
      ( withManager configuration $ \manager ->
          validateBatches
            scope
            2
            ( \name -> do
                result <- withManagedDatabaseClassified manager baseline scenario Lease.ReleaseAlways (const False) (const (checkCancellation scope))
                pure (ValidationResult name (either (Left . leaseError "fixture-validate" (Just name)) (Right . Lease.timings) result))
            )
            ["unsafe", "ordinary", "pending"]
      )
      $ \workers -> do
        readMVar ready
        threadDelay 100000
        raiseSignal sigINT
        results <- Async.wait workers
        assert "signal wins command aggregate status" =<< ((== Just 2) <$> cancellationSignal scope)
        let errors = [problem | ValidationResult {result = Left problem} <- results]
        assert "sibling errors survive shared cancellation" (any (\CliError {code} -> code == "clone_preparation_cleanup_failed") errors && any (\CliError {code} -> code == "clone_preparation_failed") errors && any (\CliError {code} -> code == "command_cancelled") errors)
        mapM_ (\CliError {errorLeaseId} -> mapM_ (void . Cleanup.releaseLease configuration) errorLeaseId) errors
  where
    preservation configuration settings scenario outerDeadline = withCancellationScope $ \scope -> do
      called <- newIORef False
      limit <- require (mkPositive "test deadline" 600)
      let hook = HookSettings (Just "/bin/sh") ["-c", if outerDeadline then "sleep 30" else "exit 0"] Nothing [] Nothing 10000
          selected = settings {clonePreparation = hook}
          bounded = if outerDeadline then configuration {Config.acquisitionDeadlineMs = limit} else configuration
      (baseline, _) <- require =<< prepareBaselineWithRunner (runChildWithCleanupCheck (pure False)) scope bounded selected
      result <- withManager bounded $ \manager -> withManagedDatabaseClassified manager baseline scenario Lease.ReleaseAlways (const False) (\_ -> writeIORef called True)
      assert "unsafe preparation prevents consumer" . not =<< readIORef called
      case result of
        Left problem@Lease.LeaseError {preparationContext = Just Lease.PreparationContext {preparationLeaseId}} -> do
          let CliError {code} = leaseError "lease-acquire" Nothing problem
          assert "unsafe preparation has stable diagnostic" (code == "clone_preparation_cleanup_failed")
          inspected <- require =<< Cleanup.inspectLease bounded preparationLeaseId
          assert "unsafe preparation preserves inspectable ownership" (case inspected of Just Cleanup.CleanupCandidate {state = "Preserved"} -> True; _ -> False)
          void (require =<< Cleanup.releaseLease bounded preparationLeaseId)
        _ -> fail ("unsafe preparation lost context: " <> show result)

-- The seam records uncertainty after doing real process-group cleanup;
-- explicit release here is safe because this test knows the injection.

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

require :: (Show e) => Either e a -> IO a
require = either (fail . show) pure

waitFile :: FilePath -> IO ()
waitFile path = do
  ready <- timeout 2000000 loop
  assert "child readiness" (ready == Just ())
  where
    loop = doesFileExist path >>= \found -> unless found (threadDelay 10000 >> loop)
