-- | The sole owner of a libpq connection and its protocol state.
module Hinagata.Postgres.Internal.Libpq
  ( Session,
    SessionOptions (..),
    defaultSessionOptions,
    sessionIdentity,
    withSession,
    runExclusive,
    SessionDisposition (..),
    query,
    drainResults,
    awaitResult,
    flushOutput,
    awaitReadable,
    awaitWritable,
    Deadline,
    deadlineAfter,
  )
where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, bracket, finally, mask, throwIO, try)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Word (Word64)
import Database.PostgreSQL.LibPQ qualified as PQ
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (threadWaitRead, threadWaitWrite)
import Hinagata.Connection
import Hinagata.Postgres.Error
import Hinagata.Prelude
import System.Posix.Types (Fd)
import System.Timeout (timeout)

-- | Positive timeouts in milliseconds. The operation deadline covers the
-- whole transaction; cleanup gets a fresh, separately bounded deadline.
data SessionOptions = SessionOptions
  { connectDeadlineMs :: !Int,
    operationDeadlineMs :: !Int,
    statementDeadlineMs :: !Int,
    lockDeadlineMs :: !Int,
    cleanupDeadlineMs :: !Int
  }
  deriving stock (Eq, Show)

-- | Five-second connect/cleanup deadlines, five-minute operation and
-- statement deadlines, and a 30-second lock deadline.
defaultSessionOptions :: SessionOptions
defaultSessionOptions = SessionOptions 5000 300000 300000 30000 5000

data State = Open | Closed
  deriving stock (Eq, Show)

-- | Opaque owner of a single native connection. Use 'withSession' to bracket it.
data Session = Session
  { connection :: !PQ.Connection,
    gate :: !(MVar State),
    options :: !SessionOptions,
    identity :: !Text
  }

sessionIdentity :: Session -> Text
sessionIdentity Session {identity} = identity

data SessionDisposition a = Keep !a | Retire !a

newtype Deadline = Deadline Word64

deadlineAfter :: Int -> IO Deadline
deadlineAfter milliseconds = do
  now <- getMonotonicTimeNSec
  pure (Deadline (now + fromIntegral (max 1 milliseconds) * 1000000))

-- | Open and bracket a connection to the explicit target. A failed Unix socket
-- connection does not retry through TCP. Callback exceptions propagate after
-- the connection closes.
withSession :: ConnectionTarget -> SessionOptions -> (Session -> IO a) -> IO (Either SessionError a)
withSession target options action = do
  opened <- openSession target options
  case opened of
    Left failure -> pure (Left failure)
    Right session -> Right <$> bracket (pure session) closeSession action

openSession :: ConnectionTarget -> SessionOptions -> IO (Either SessionError Session)
openSession target options
  | any (<= 0) [connectDeadlineMs options, operationDeadlineMs options, statementDeadlineMs options, lockDeadlineMs options, cleanupDeadlineMs options] = pure (Left InvalidSessionOptions)
  | otherwise = do
      let identity = Text.pack (show target)
          connectionInfo = Encoding.encodeUtf8 (connectionStringText (renderConnectionString target))
      started <- try @IOException (PQ.connectStart connectionInfo)
      case started of
        Left _ -> pure (Left (ConnectionFailed identity))
        Right connection -> do
          deadline <- deadlineAfter (connectDeadlineMs options)
          outcome <- try @IOException (poll connection deadline)
          case outcome of
            Left _ -> PQ.finish connection >> pure (Left (ConnectionFailed identity))
            Right False -> PQ.finish connection >> pure (Left (ConnectionTimedOut identity))
            Right True -> do
              nonblocking <- PQ.setnonblocking connection True
              if not nonblocking
                then PQ.finish connection >> pure (Left (ConnectionFailed identity))
                else do
                  gate <- newMVar Open
                  pure (Right Session {connection, gate, options, identity})
  where
    poll connection deadline = do
      status <- PQ.connectPoll connection
      case status of
        PQ.PollingOk -> pure True
        PQ.PollingFailed -> pure False
        PQ.PollingReading -> awaitReadable connection deadline >>= \ready -> if ready then poll connection deadline else pure False
        PQ.PollingWriting -> awaitWritable connection deadline >>= \ready -> if ready then poll connection deadline else pure False

closeSession :: Session -> IO ()
closeSession Session {connection, gate} =
  modifyMVar_ gate $ \case
    Open -> PQ.finish connection >> pure Closed
    Closed -> pure Closed

-- | A simultaneous use fails immediately. An asynchronous exception closes
-- the connection, causing PostgreSQL to roll back its open transaction.
runExclusive :: Session -> (PQ.Connection -> SessionOptions -> IO (SessionDisposition a)) -> IO (Either SessionError a)
runExclusive Session {connection, gate, options} action = mask $ \restore -> do
  acquired <- tryTakeMVar gate
  case acquired of
    Nothing -> pure (Left SessionBusy)
    Just Closed -> putMVar gate Closed >> pure (Left SessionClosed)
    Just Open -> do
      result <- try @SomeException (restore (action connection options))
      case result of
        Right (Keep value) -> putMVar gate Open >> pure (Right value)
        Right (Retire value) -> do
          PQ.finish connection `finally` putMVar gate Closed
          pure (Right value)
        Left failure -> do
          requestCancel connection
          PQ.finish connection `finally` putMVar gate Closed
          throwIO failure

-- | Cancellation is best-effort and bounded. Closing the connection remains
-- the authoritative rollback when the protocol was interrupted.
requestCancel :: PQ.Connection -> IO ()
requestCancel connection = do
  handle <- try @SomeException (PQ.getCancel connection)
  case handle of
    Left _ -> pure ()
    Right Nothing -> pure ()
    Right (Just cancelHandle) -> do
      finished <- newEmptyMVar
      _ <- forkIOWithUnmask $ \unmask -> do
        _ <- try @SomeException (unmask (PQ.cancel cancelHandle))
        putMVar finished ()
      void (timeout 1000000 (takeMVar finished))

-- | Send and drain a query without retaining result rows. Result status is
-- checked for every statement, including the final COMMIT result.
query :: PQ.Connection -> Deadline -> NativePhase -> ByteString -> IO (Either NativeError ())
query connection deadline phase statement = do
  sent <- PQ.sendQuery connection statement
  if not sent
    then pure (Left (NativeError phase Nothing "libpq refused query dispatch"))
    else do
      singleRows <- PQ.setSingleRowMode connection
      if not singleRows
        then pure (Left (NativeError phase Nothing "libpq refused single-row result mode"))
        else do
          flushed <- flushOutput connection deadline
          if not flushed
            then pure (Left (NativeError phase Nothing "query output could not be flushed before deadline"))
            else drainResults connection deadline phase

drainResults :: PQ.Connection -> Deadline -> NativePhase -> IO (Either NativeError ())
drainResults connection deadline phase = collect False Nothing
  where
    collect seenResult firstError = do
      ready <- awaitResult connection deadline
      if not ready
        then pure (Left (NativeError phase Nothing "query timed out or connection failed"))
        else do
          next <- PQ.getResult connection
          case next of
            Nothing -> pure (maybe (if seenResult then Right () else Left (NativeError phase Nothing "query returned no result")) Left firstError)
            Just result -> do
              status <- PQ.resultStatus result
              state <- PQ.resultErrorField result PQ.DiagSqlstate
              let failure =
                    if status `elem` [PQ.CommandOk, PQ.TuplesOk, PQ.SingleTuple]
                      then firstError
                      else firstError <|> Just (NativeError phase (Encoding.decodeUtf8 <$> state) (Text.pack (show status)))
              collect True failure

awaitResult :: PQ.Connection -> Deadline -> IO Bool
awaitResult connection deadline = do
  busy <- PQ.isBusy connection
  if not busy
    then pure True
    else do
      ready <- awaitReadable connection deadline
      if not ready
        then pure False
        else do
          consumed <- PQ.consumeInput connection
          if consumed then awaitResult connection deadline else pure False

flushOutput :: PQ.Connection -> Deadline -> IO Bool
flushOutput connection deadline = do
  status <- PQ.flush connection
  case status of
    PQ.FlushOk -> pure True
    PQ.FlushFailed -> pure False
    PQ.FlushWriting -> awaitWritable connection deadline >>= \ready -> if ready then flushOutput connection deadline else pure False

awaitReadable :: PQ.Connection -> Deadline -> IO Bool
awaitReadable connection deadline = waitFor threadWaitRead connection deadline

awaitWritable :: PQ.Connection -> Deadline -> IO Bool
awaitWritable connection deadline = waitFor threadWaitWrite connection deadline

waitFor :: (Fd -> IO ()) -> PQ.Connection -> Deadline -> IO Bool
waitFor operation connection (Deadline limit) = do
  now <- getMonotonicTimeNSec
  descriptor <- PQ.socket connection
  case descriptor of
    Nothing -> pure False
    Just fd
      | now >= limit -> pure False
      | otherwise -> isJust <$> timeout (fromIntegral (min (fromIntegral (maxBound :: Int)) ((limit - now) `div` 1000))) (operation fd)
