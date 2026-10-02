-- | Bounded COPY FROM STDIN with a single nonblocking libpq protocol owner.
module Hinagata.Postgres.Internal.Copy
  ( copyCsv,
  )
where

import Control.Exception (IOException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Word (Word64)
import Database.PostgreSQL.LibPQ qualified as PQ
import Hinagata.Fixture.Bundle (CapturedStep (..))
import Hinagata.Fixture.Types (CopySpec (..))
import Hinagata.Postgres.Error
import Hinagata.Postgres.Internal.Libpq
import Hinagata.Prelude
import Hinagata.Types (quoteSqlIdentifier)
import Numeric (showHex)
import System.IO (IOMode (ReadMode), withBinaryFile)

copyCsv :: PQ.Connection -> Deadline -> FilePath -> CapturedStep -> IO (Either NativeError Word64)
copyCsv connection deadline path step =
  case step of
    CapturedCopy {copySpec, contentDigest, byteLength} -> do
      begun <- startCopy connection deadline copySpec
      case begun of
        Left failure -> pure (Left failure)
        Right () -> do
          transferred <- try @IOException (withBinaryFile path ReadMode (stream byteLength contentDigest))
          case transferred of
            Left _ -> do
              abortCopy connection deadline
              pure (Left (NativeError Copy Nothing "COPY bundle file could not be read"))
            Right (Left failure) -> do
              abortCopy connection deadline
              pure (Left failure)
            Right (Right count) -> do
              ended <- endCopy connection deadline
              pure (count <$ ended)
    _ -> pure (Left (NativeError Copy Nothing "expected captured CSV step"))
  where
    stream expected digest input = go input 0 SHA256.init
      where
        go handle count context = do
          bytes <- ByteString.hGet handle 65536
          if ByteString.null bytes
            then
              if count == expected && hex (SHA256.finalize context) == digest
                then pure (Right count)
                else pure (Left (NativeError Copy Nothing "COPY bundle bytes changed"))
            else do
              sent <- sendChunk connection deadline bytes
              case sent of
                Left failure -> pure (Left failure)
                Right () -> do
                  let nextCount = count + fromIntegral (ByteString.length bytes)
                      nextContext = SHA256.update context bytes
                  nextContext `seq` go handle nextCount nextContext

startCopy :: PQ.Connection -> Deadline -> CopySpec -> IO (Either NativeError ())
startCopy connection deadline spec = do
  sent <- PQ.sendQuery connection (renderCopy spec)
  if not sent
    then pure (Left (NativeError Copy Nothing "libpq refused COPY dispatch"))
    else do
      flushed <- flushOutput connection deadline
      if not flushed
        then pure (Left (NativeError Copy Nothing "COPY dispatch timed out"))
        else do
          ready <- awaitResult connection deadline
          if not ready
            then pure (Left (NativeError Copy Nothing "COPY start timed out"))
            else do
              result <- PQ.getResult connection
              case result of
                Nothing -> pure (Left (NativeError Copy Nothing "COPY returned no start result"))
                Just value -> do
                  status <- PQ.resultStatus value
                  if status == PQ.CopyIn
                    then pure (Right ())
                    else do
                      state <- PQ.resultErrorField value PQ.DiagSqlstate
                      _ <- drainResults connection deadline Copy
                      pure (Left (NativeError Copy (Encoding.decodeUtf8 <$> state) ("COPY start returned " <> Text.pack (show status))))

sendChunk :: PQ.Connection -> Deadline -> ByteString -> IO (Either NativeError ())
sendChunk connection deadline bytes = do
  outcome <- PQ.putCopyData connection bytes
  case outcome of
    PQ.CopyInOk -> do
      -- Nonblocking libpq queues successful COPY writes until PQflush. Drain
      -- each bounded chunk so client memory cannot grow with fixture size.
      flushed <- flushOutput connection deadline
      pure $ if flushed then Right () else Left (NativeError Copy Nothing "COPY data flush timed out")
    PQ.CopyInError -> pure (Left (NativeError Copy Nothing "COPY data transfer failed"))
    PQ.CopyInWouldBlock -> do
      flushed <- flushOutput connection deadline
      if not flushed
        then pure (Left (NativeError Copy Nothing "COPY data flush timed out"))
        else do
          ready <- awaitWritable connection deadline
          if ready then sendChunk connection deadline bytes else pure (Left (NativeError Copy Nothing "COPY transfer timed out"))

endCopy :: PQ.Connection -> Deadline -> IO (Either NativeError ())
endCopy connection deadline = do
  outcome <- PQ.putCopyEnd connection Nothing
  case outcome of
    PQ.CopyInOk -> do
      flushed <- flushOutput connection deadline
      if flushed then drainResults connection deadline Copy else pure (Left (NativeError Copy Nothing "COPY end flush timed out"))
    PQ.CopyInError -> pure (Left (NativeError Copy Nothing "COPY end failed"))
    PQ.CopyInWouldBlock -> do
      flushed <- flushOutput connection deadline
      if not flushed
        then pure (Left (NativeError Copy Nothing "COPY end flush timed out"))
        else do
          ready <- awaitWritable connection deadline
          if ready then endCopy connection deadline else pure (Left (NativeError Copy Nothing "COPY end timed out"))

abortCopy :: PQ.Connection -> Deadline -> IO ()
abortCopy connection deadline = do
  outcome <- PQ.putCopyEnd connection (Just "Hinagata bundle transfer failed")
  case outcome of
    PQ.CopyInOk -> do
      _ <- flushOutput connection deadline
      _ <- drainResults connection deadline Copy
      pure ()
    PQ.CopyInWouldBlock -> do
      flushed <- flushOutput connection deadline
      when flushed $ do
        ready <- awaitWritable connection deadline
        when ready (abortCopy connection deadline)
    PQ.CopyInError -> pure ()

renderCopy :: CopySpec -> ByteString
renderCopy CopySpec {schema, table, columns, header} =
  Encoding.encodeUtf8 $
    "COPY "
      <> quoteSqlIdentifier schema
      <> "."
      <> quoteSqlIdentifier table
      <> " ("
      <> Text.intercalate ", " (map quoteSqlIdentifier columns)
      <> ") FROM STDIN WITH (FORMAT csv, HEADER "
      <> (if header then "true" else "false")
      <> ")"

hex :: ByteString -> Text
hex = Text.pack . concatMap digits . ByteString.unpack
  where
    digits byte = case showHex byte "" of
      [digit] -> ['0', digit]
      value -> value
