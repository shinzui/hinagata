-- | Generic, shell-free child execution with a private PostgreSQL password channel.
module Hinagata.Cli.Process
  ( ChildSpec (..),
    ChildReport (..),
    ChildFailure (..),
    runChild,
    parseOverlay,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (IOException, bracket, finally, mask, onException, try)
import Control.Monad (unless, void, when)
import Data.List (isPrefixOf)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Hinagata.Connection
import Hinagata.Types (databaseNameText, portNumber)
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), hClose, hFlush, hIsClosed, stderr, withFile)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import System.Posix.Signals (Handler (Catch), installHandler, nullSignal, sigINT, sigKILL, sigTERM, signalProcessGroup)
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

runChild :: ChildSpec -> IO (Either ChildFailure ChildReport)
runChild specification@ChildSpec {target} =
  withPasswordFile target $ \passwordPath -> do
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
      let child =
            (proc (executable specification) (arguments specification))
              { cwd = workingDirectory specification,
                env = Just processEnvironment,
                std_in = UseHandle nullInput,
                std_out = if stdoutToStderr specification then UseHandle stderr else Inherit,
                create_group = True,
                delegate_ctlc = False
              }
      signalSeen <- newSignalMarker
      processPid <- newMVar Nothing
      forwardedSignal <- newMVar False
      escalation <- newMVar (Nothing :: Maybe ThreadId)
      finished <- newMVar False
      let launch signal = do
            maybePid <- readMVar processPid
            case maybePid of
              Nothing -> pure ()
              Just pid -> do
                firstForward <- modifyMVar forwardedSignal (\already -> pure (True, not already))
                when firstForward $ do
                  _ <- try @IOException (signalProcessGroup signal pid)
                  timer <- forkIO $ do
                    threadDelay 5000000
                    done <- readMVar finished
                    unless done $ do
                      alive <- groupAlive pid
                      when alive (void (try @IOException (signalProcessGroup sigKILL pid)))
                  modifyMVar_ escalation (const (pure (Just timer)))
          forward signal number = do
            _ <- writeSignalMarker signalSeen number
            launch signal
      previousInt <- installHandler sigINT (Catch (forward sigINT 2)) Nothing
      previousTerm <- installHandler sigTERM (Catch (forward sigTERM 15)) Nothing
      let restoreHandlers = do
            modifyMVar_ finished (const (pure True))
            _ <- installHandler sigINT previousInt Nothing
            _ <- installHandler sigTERM previousTerm Nothing
            pending <- readMVar escalation
            maybe (pure ()) killThread pending
            pure ()
          supervise = do
            spawned <- try @IOException (createProcess child)
            case spawned of
              Left _ -> pure (Left ChildSpawnFailed)
              Right (_, _, _, handle) -> do
                maybePid <- getPid handle
                case maybePid of
                  Nothing -> do
                    _ <- try @IOException (waitForProcess handle)
                    pure (Left ChildIdentityUnavailable)
                  Just pid -> do
                    modifyMVar_ processPid (const (pure (Just pid)))
                    pending <- readSignalMarker signalSeen
                    maybe (pure ()) (\number -> launch (if number == 2 then sigINT else sigTERM)) pending
                    let waitForChild = do
                          waited <- case deadlineMs specification of
                            Nothing -> Just <$> restore (waitExit handle)
                            Just milliseconds -> restore (timeout (milliseconds * 1000) (waitExit handle))
                          stopped <- stopGroup pid
                          when (waited == Nothing) (void (timeout 2000000 (try @IOException (waitForProcess handle))))
                          cancellation <- readSignalMarker signalSeen
                          pure (Right (ChildReport waited (waited == Nothing) cancellation stopped))
                    waitForChild `onException` (void (stopGroup pid) >> void (timeout 2000000 (try @IOException (waitForProcess handle))))
      supervise `finally` restoreHandlers

stopGroup :: System.Posix.Types.ProcessID -> IO (Maybe Text.Text)
stopGroup groupId = do
  alive <- groupAlive groupId
  if not alive
    then pure Nothing
    else do
      _ <- try @IOException (signalProcessGroup sigTERM groupId)
      stopped <- waitGone groupId 40
      if stopped
        then pure Nothing
        else do
          _ <- try @IOException (signalProcessGroup sigKILL groupId)
          killed <- waitGone groupId 40
          pure (if killed then Nothing else Just "child process group could not be proven stopped")

waitGone :: System.Posix.Types.ProcessID -> Int -> IO Bool
waitGone groupId attempts = do
  alive <- groupAlive groupId
  if not alive then pure True else if attempts <= 0 then pure False else threadDelay 50000 >> waitGone groupId (attempts - 1)

groupAlive :: System.Posix.Types.ProcessID -> IO Bool
groupAlive groupId = do
  result <- try @IOException (signalProcessGroup nullSignal groupId)
  pure $ case result of
    Right () -> True
    Left problem -> not (isDoesNotExistError problem)

waitExit :: ProcessHandle -> IO ExitCode
waitExit handle = do
  completed <- getProcessExitCode handle
  case completed of
    Just status -> pure status
    Nothing -> threadDelay 50000 >> waitExit handle

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

newtype SignalMarker = SignalMarker (MVar (Maybe Int))

newSignalMarker :: IO SignalMarker
newSignalMarker = SignalMarker <$> newMVar Nothing

writeSignalMarker :: SignalMarker -> Int -> IO Bool
writeSignalMarker (SignalMarker variable) number = modifyMVar variable (\previous -> pure (previous <|> Just number, previous == Nothing))

readSignalMarker :: SignalMarker -> IO (Maybe Int)
readSignalMarker (SignalMarker variable) = readMVar variable
