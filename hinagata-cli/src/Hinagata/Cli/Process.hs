-- | Generic, shell-free child execution with a private PostgreSQL password channel.
module Hinagata.Cli.Process
  ( ChildSpec (..),
    ChildReport (..),
    ChildFailure (..),
    CancellationScope,
    CommandCancelled (..),
    ChildCleanupException (..),
    withCancellationScope,
    withCommandCancellation,
    withCooperativeCancellation,
    cancellationSignal,
    checkCancellation,
    waitCancellation,
    runChild,
    runChildWithCleanupCheck,
    withRegistration,
    parseOverlay,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Exception (Exception (..), IOException, SomeException, asyncExceptionFromException, asyncExceptionToException, bracket, bracket_, finally, mask, throwIO, try)
import Control.Monad (unless, void)
import Data.List (isPrefixOf)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Hinagata.Connection
import Hinagata.Types (databaseNameText, portNumber)
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), hClose, hFlush, hIsClosed, stderr, withFile)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import System.Posix.Signals (Handler (Catch), Signal, installHandler, nullSignal, sigINT, sigKILL, sigTERM, signalProcessGroup)
import System.Posix.Temp (mkstemp)
import System.Posix.Types qualified
import System.Process (CreateProcess (..), ProcessHandle, StdStream (Inherit, UseHandle), createProcess, getPid, getProcessExitCode, proc, waitForProcess)
import System.Timeout (timeout)

data ChildSpec = ChildSpec
  { executable :: !FilePath,
    arguments :: ![String],
    workingDirectory :: !(Maybe FilePath),
    environment :: ![(String, String)],
    target :: !ConnectionTarget,
    identifiers :: !(Maybe (Text.Text, Text.Text)),
    deadlineMs :: !(Maybe Int),
    stdoutToStderr :: !Bool
  }

data ChildReport = ChildReport
  { childExit :: !(Maybe ExitCode),
    timedOut :: !Bool,
    cancelledBy :: !(Maybe Int),
    cleanupFailure :: !(Maybe Text.Text)
  }
  deriving stock (Eq, Show)

data ChildFailure = ChildSpawnFailed | ChildIdentityUnavailable
  deriving stock (Eq, Show)

-- | Explicit hook overlays cannot replace the managed PostgreSQL connection
-- or inject a shell through argument splitting.
parseOverlay :: [Text.Text] -> Either Text.Text [(String, String)]
parseOverlay = traverse parseOne
  where
    parseOne entry =
      let (name, rest) = Text.breakOn "=" entry
       in if not (validName name) || Text.null rest || Text.any (== '\0') rest
            then Left "hook environment entries must be NAME=VALUE without NUL"
            else
              if "PG" `Text.isPrefixOf` name || "HINAGATA_" `Text.isPrefixOf` name
                then Left "hook environment cannot override managed PG* or HINAGATA_* variables"
                else Right (Text.unpack name, Text.unpack (Text.drop 1 rest))

    validName name = case Text.uncons name of
      Nothing -> False
      Just (initial, following) -> (initial == '_' || asciiLetter initial) && Text.all (\character -> character == '_' || asciiLetter character || asciiDigit character) following
    asciiLetter character = ('A' <= character && character <= 'Z') || ('a' <= character && character <= 'z')
    asciiDigit character = '0' <= character && character <= '9'

-- | One command owns process-wide handlers. Registration and first-signal
-- observation share a lock, so spawning cannot miss concurrent cancellation.
data ScopeState = ScopeState
  { selectedSignal :: !(Maybe Int),
    nextRegistration :: !Int,
    registrations :: ![(Int, MVar Int)],
    cooperative :: !Int,
    deferRoot :: !Bool
  }

newtype CancellationScope = CancellationScope (MVar ScopeState)

data CommandCancelled = CommandCancelled !Int
  deriving stock (Show)

instance Exception CommandCancelled where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

data ChildCleanupException = ChildCleanupException
  deriving stock (Show)
  deriving anyclass (Exception)

withCancellationScope :: (CancellationScope -> IO a) -> IO a
withCancellationScope callback = mask $ \restore -> do
  scope@(CancellationScope state) <- CancellationScope <$> newMVar (ScopeState Nothing 0 [] 0 False)
  let notify number = modifyMVar_ state $ \record@ScopeState {selectedSignal, registrations, cooperative, deferRoot} -> do
        let selected = selectedSignal <|> Just number
            deferred = case selectedSignal of
              Just _ -> deferRoot
              Nothing -> cooperative > 0 || not (null registrations)
        mapM_ (\(_, marker) -> void (tryPutMVar marker (maybe number id selected))) registrations
        pure record {selectedSignal = selected, deferRoot = deferred}
      settle = do
        ScopeState {registrations = children} <- readMVar state
        unless (null children) (threadDelay 10000 >> settle)
  previousInt <- installHandler sigINT (Catch (notify 2)) Nothing
  previousTerm <- installHandler sigTERM (Catch (notify 15)) Nothing
  restore (callback scope)
    `finally` ( settle `finally` do
                  _ <- installHandler sigINT previousInt Nothing
                  _ <- installHandler sigTERM previousTerm Nothing
                  pure ()
              )

cancellationSignal :: CancellationScope -> IO (Maybe Int)
cancellationSignal (CancellationScope state) = do
  ScopeState {selectedSignal = signal} <- readMVar state
  pure signal

checkCancellation :: CancellationScope -> IO ()
checkCancellation scope = cancellationSignal scope >>= maybe (pure ()) (throwIO . CommandCancelled)

waitCancellation :: CancellationScope -> IO Int
waitCancellation scope = cancellationSignal scope >>= maybe (threadDelay 10000 >> waitCancellation scope) pure

-- | The root cancels native work once and joins cleanup. If the first signal
-- arrives inside an existing child/validation supervisor, that supervisor owns
-- delivery through its typed outcome; the root only joins it. This decision is
-- latched with the signal, so unregistering cannot cause a second interruption.
withCommandCancellation :: CancellationScope -> IO a -> IO a
withCommandCancellation scope@(CancellationScope state) action =
  Async.withAsync (checkCancellation scope >> action) $ \worker -> do
    raced <- Async.race (Async.waitCatch worker) (waitCancellation scope)
    completed <- case raced of
      Left result -> pure result
      Right signal -> do
        ScopeState {deferRoot} <- readMVar state
        unless deferRoot (Async.cancelWith worker (CommandCancelled signal))
        Async.waitCatch worker
    either throwIO pure completed

-- | Delegate first-signal delivery to an existing supervisor. Its cleanup and
-- typed outcome must settle before leaving this region.
withCooperativeCancellation :: CancellationScope -> IO a -> IO a
withCooperativeCancellation (CancellationScope state) = bracket_ enter leave
  where
    enter = modifyMVar_ state (\record -> pure record {cooperative = cooperative record + 1})
    leave = modifyMVar_ state (\record -> pure record {cooperative = cooperative record - 1})

withRegistration :: CancellationScope -> (MVar Int -> IO a) -> IO a
withRegistration (CancellationScope state) callback = bracket register unregister (callback . snd)
  where
    register = do
      marker <- newEmptyMVar
      modifyMVar state $ \record@ScopeState {selectedSignal, nextRegistration, registrations} -> do
        mapM_ (void . tryPutMVar marker) selectedSignal
        pure (record {nextRegistration = nextRegistration + 1, registrations = (nextRegistration, marker) : registrations}, (nextRegistration, marker))
    unregister (key, _) = modifyMVar_ state $ \record@ScopeState {registrations} ->
      pure record {registrations = filter ((/= key) . fst) registrations}

runChild :: CancellationScope -> ChildSpec -> IO (Either ChildFailure ChildReport)
runChild = runChildWithCleanupCheck (pure True)

-- | Internal test seam: a negative proof forces retention after real cleanup.
-- There is deliberately no environment or configuration switch for this.
runChildWithCleanupCheck :: IO Bool -> CancellationScope -> ChildSpec -> IO (Either ChildFailure ChildReport)
runChildWithCleanupCheck cleanupCheck scope specification@ChildSpec {target} = do
  checkCancellation scope
  withRegistration scope $ \marker -> withPasswordFile target $ \passwordPath -> do
    inherited <- getEnvironment
    let forwarded = filter (\(name, _) -> not ("PG" `isPrefixOf` name || "HINAGATA_" `isPrefixOf` name)) inherited
        connectionEnvironment =
          [ ("PGHOST", Text.unpack (hostText (connectionHost target))),
            ("PGPORT", show (portNumber (connectionPort target))),
            ("PGUSER", Text.unpack (connectionUser target)),
            ("PGDATABASE", Text.unpack (databaseNameText (connectionDatabase target)))
          ]
        identityEnvironment = case identifiers specification of
          Nothing -> []
          Just (runId, leaseId) -> [("HINAGATA_RUN_ID", Text.unpack runId), ("HINAGATA_LEASE_ID", Text.unpack leaseId)]
        passwordEnvironment = maybe [] (\path -> [("PGPASSFILE", path)]) passwordPath
        overlayNames = map fst (environment specification)
        processEnvironment = environment specification <> connectionEnvironment <> identityEnvironment <> passwordEnvironment <> filter (\(name, _) -> name `notElem` overlayNames) forwarded
    withFile "/dev/null" ReadMode $ \nullInput -> mask $ \restore -> do
      checkCancellation scope
      let child =
            (proc (executable specification) (arguments specification))
              { cwd = workingDirectory specification,
                env = Just processEnvironment,
                std_in = UseHandle nullInput,
                std_out = if stdoutToStderr specification then UseHandle stderr else Inherit,
                create_group = True,
                delegate_ctlc = False
              }
      spawned <- try @IOException (createProcess child)
      case spawned of
        Left _ -> pure (Left ChildSpawnFailed)
        Right (_, _, _, handle) -> do
          maybePid <- getPid handle
          case maybePid of
            Nothing -> pure (Left ChildIdentityUnavailable)
            Just pid -> do
              let stop = do
                    signal <- cancellationSignal scope
                    attempted <- try @IOException $ do
                      stopped <- stopGroup (maybe sigTERM (\number -> if number == 2 then sigINT else sigTERM) signal) pid handle
                      _ <- timeout 2000000 (try @IOException (waitForProcess handle))
                      pure stopped
                    proven <- cleanupCheck
                    pure (if proven then either (const (Just "child process cleanup could not be observed")) id attempted else Just "child process group could not be proven stopped")
                  wait = do
                    signal <- tryReadMVar marker
                    case signal of
                      Just _ -> pure Nothing
                      Nothing -> do
                        completed <- getProcessExitCode handle
                        case completed of
                          Just status -> pure (Just status)
                          Nothing -> threadDelay 10000 >> wait
                  supervise = do
                    waited <- case deadlineMs specification of
                      Nothing -> Just <$> restore wait
                      Just milliseconds -> restore (timeout (milliseconds * 1000) wait)
                    stopped <- stop
                    signal <- cancellationSignal scope
                    pure (Right (ChildReport (waited >>= id) (waited == Nothing) signal stopped))
              result <- try @SomeException supervise
              case result of
                Right report -> pure report
                Left exception -> do
                  stopped <- stop
                  case stopped of
                    Just _ -> throwIO ChildCleanupException
                    Nothing -> throwIO exception

-- | Bounded escalation also reaps the leader while checking the group.
stopGroup :: System.Posix.Signals.Signal -> System.Posix.Types.ProcessID -> ProcessHandle -> IO (Maybe Text.Text)
stopGroup signal groupId handle = do
  alive <- groupAlive groupId
  if not alive
    then pure Nothing
    else do
      _ <- try @IOException (signalProcessGroup signal groupId)
      stopped <- waitGone 40
      if stopped
        then pure Nothing
        else do
          _ <- try @IOException (signalProcessGroup sigKILL groupId)
          killed <- waitGone 40
          pure (if killed then Nothing else Just "child process group could not be proven stopped")
  where
    waitGone attempts = do
      _ <- getProcessExitCode handle
      alive <- groupAlive groupId
      if not alive then pure True else if attempts <= (0 :: Int) then pure False else threadDelay 50000 >> waitGone (attempts - 1)

groupAlive :: System.Posix.Types.ProcessID -> IO Bool
groupAlive groupId = do
  result <- try @IOException (signalProcessGroup nullSignal groupId)
  pure $ case result of
    Right () -> True
    Left problem -> not (isDoesNotExistError problem)

withPasswordFile :: ConnectionTarget -> (Maybe FilePath -> IO a) -> IO a
withPasswordFile target callback = case connectionPassword target of
  Nothing -> callback Nothing
  Just password -> do
    temporary <- getTemporaryDirectory
    bracket (mkstemp (temporary </> "hinagata-pgpass-")) removePassword $ \(path, handle) -> do
      setFileMode path (ownerReadMode `unionFileModes` ownerWriteMode)
      TextIO.hPutStrLn handle (passwordLine target password)
      hFlush handle
      hClose handle
      callback (Just path)
  where
    removePassword (path, handle) = do
      closed <- hIsClosed handle
      unless closed (hClose handle)
      removeFile path

passwordLine :: ConnectionTarget -> Secret -> Text.Text
passwordLine target password =
  Text.intercalate ":" (map escape [hostText (connectionHost target), Text.pack (show (portNumber (connectionPort target))), databaseNameText (connectionDatabase target), connectionUser target, secretText password])
  where
    escape = Text.concatMap (\character -> if character == ':' || character == '\\' then Text.pack ['\\', character] else Text.singleton character)
