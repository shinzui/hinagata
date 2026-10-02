-- | Atomic direct loading into a caller-selected, already migrated database.
module Hinagata.Postgres.Internal.Load
  ( LoadReport (..),
    loadPlan,
    loadInto,
    loadComposedRemainder,
  )
where

import Control.Exception (IOException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Word (Word64)
import Database.PostgreSQL.LibPQ qualified as PQ
import GHC.Clock (getMonotonicTimeNSec)
import Hinagata.Connection (ConnectionTarget)
import Hinagata.Fixture.Bundle
import Hinagata.Fixture.Types (FixtureName)
import Hinagata.Postgres.Error
import Hinagata.Postgres.Internal.Copy (copyCsv)
import Hinagata.Postgres.Internal.Libpq
import Hinagata.Postgres.Internal.Sql
import Hinagata.Prelude
import Numeric (showHex)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)

-- | Counts and wall-clock stages for a committed fixture plan. @bytesSent@
-- counts transferred SQL and CSV bytes, not inferred database rows.
data LoadReport = LoadReport
  { fixtureCount :: !Int,
    stepCount :: !Int,
    bytesSent :: !Word64,
    verifyMs :: !Word64,
    setupMs :: !Word64,
    sqlMs :: !Word64,
    copyMs :: !Word64,
    commitMs :: !Word64,
    elapsedMs :: !Word64
  }
  deriving stock (Eq, Show)

-- | Open one session, load a verified plan, and close the session. The target
-- database must already exist and contain the schema expected by the fixture.
-- This operation never deletes or resets it.
loadInto :: ConnectionTarget -> SessionOptions -> FixturePlan -> IO (Either LoadError LoadReport)
loadInto target options plan = do
  outcome <- withSession target options (\session -> loadPlan session plan)
  pure $ case outcome of
    Left failure -> Left ((sessionError failure) {targetIdentity = Just (Text.pack (show target))})
    Right value -> value

-- | Load a plan into a reusable Hinagata session under one transaction.
-- Concurrent calls on that session fail with @SessionBusy@; an uncertain
-- connection is retired instead of returned to the caller for reuse.
loadPlan :: Session -> FixturePlan -> IO (Either LoadError LoadReport)
loadPlan session plan = loadSelected True session plan (map (CapturedFixtureRef (planDirectory plan)) (planFixtures plan))

-- | Load only the exact suffix returned by composition. The lease path has
-- already verified its manifest and selected steps; streamed bytes are checked
-- against captured digests again as they are used. This stays private.
loadComposedRemainder :: Session -> FixturePlan -> ComposedPlan -> IO (Either LoadError LoadReport)
loadComposedRemainder session plan composed = loadSelected False session plan (scenarioRemainder composed)

loadSelected :: Bool -> Session -> FixturePlan -> [CapturedFixtureRef] -> IO (Either LoadError LoadReport)
loadSelected verifyBeforeLoad session plan selected = do
  verifyStart <- getMonotonicTimeNSec
  verified <- try @IOException (if verifyBeforeLoad then verifyPlan plan else pure True)
  case verified of
    Left _ -> pure (Left ((simpleError VerifyBundle "bundle verification failed") {targetIdentity = Just (sessionIdentity session)}))
    Right False -> pure (Left ((simpleError VerifyBundle "bundle changed or is incomplete") {targetIdentity = Just (sessionIdentity session)}))
    Right True -> do
      verifyEnd <- getMonotonicTimeNSec
      outcome <- runExclusive session (\connection options -> loadExclusive connection options selected ((verifyEnd - verifyStart) `div` 1000000))
      pure $ case outcome of
        Left failure -> Left ((sessionError failure) {targetIdentity = Just (sessionIdentity session)})
        Right value -> either (Left . (\failure -> failure {targetIdentity = Just (sessionIdentity session)})) Right value

loadExclusive :: PQ.Connection -> SessionOptions -> [CapturedFixtureRef] -> Word64 -> IO (SessionDisposition (Either LoadError LoadReport))
loadExclusive connection options selected verifyMs = do
  transaction <- PQ.transactionStatus connection
  if transaction /= PQ.TransIdle
    then pure (Keep (Left (simpleError BeginLoad "session is already in a transaction or failed state")))
    else do
      start <- getMonotonicTimeNSec
      deadline <- deadlineAfter (operationDeadlineMs options)
      begun <- query connection deadline Begin "BEGIN"
      case begun of
        Left problem -> pure (Retire (Left (nativeError BeginLoad Nothing Nothing problem)))
        Right () -> do
          limits <- setLocalDeadlines connection options deadline
          case limits of
            Left problem -> rollbackAfter connection options (nativeError SetLoadDeadline Nothing Nothing problem)
            Right () -> do
              setupEnd <- getMonotonicTimeNSec
              loaded <- runFixtures connection deadline selected
              case loaded of
                Left failure -> rollbackAfter connection options failure
                Right (steps, bytes, sqlNanos, copyNanos) -> do
                  commitStart <- getMonotonicTimeNSec
                  committed <- query connection deadline Commit "COMMIT"
                  case committed of
                    Left problem -> pure (Retire (Left (nativeError CommitLoad Nothing Nothing problem)))
                    Right () -> do
                      state <- PQ.transactionStatus connection
                      if state /= PQ.TransIdle
                        then pure (Retire (Left (simpleError CommitLoad "connection did not return to idle after commit")))
                        else do
                          end <- getMonotonicTimeNSec
                          pure
                            ( Keep
                                ( Right
                                    LoadReport
                                      { fixtureCount = length selected,
                                        stepCount = steps,
                                        bytesSent = bytes,
                                        verifyMs,
                                        setupMs = (setupEnd - start) `div` 1000000,
                                        sqlMs = sqlNanos `div` 1000000,
                                        copyMs = copyNanos `div` 1000000,
                                        commitMs = (end - commitStart) `div` 1000000,
                                        elapsedMs = verifyMs + (end - start) `div` 1000000
                                      }
                                )
                            )

rollbackAfter :: PQ.Connection -> SessionOptions -> LoadError -> IO (SessionDisposition (Either LoadError LoadReport))
rollbackAfter connection options failure = do
  deadline <- deadlineAfter (cleanupDeadlineMs options)
  rollback <- query connection deadline Rollback "ROLLBACK"
  case rollback of
    Right () -> do
      state <- PQ.transactionStatus connection
      if state == PQ.TransIdle
        then pure (Keep (Left failure))
        else pure (Retire (Left failure {cleanupFailure = Just "connection did not return to idle after rollback"}))
    Left cleanup -> pure (Retire (Left failure {cleanupFailure = Just (reason cleanup)}))

runFixtures :: PQ.Connection -> Deadline -> [CapturedFixtureRef] -> IO (Either LoadError (Int, Word64, Word64, Word64))
runFixtures connection deadline selected = go 0 0 0 0 selected
  where
    go count bytes sqlNanos copyNanos [] = pure (Right (count, bytes, sqlNanos, copyNanos))
    go count bytes sqlNanos copyNanos (CapturedFixtureRef directory captured : rest) = do
      next <- runSteps directory (name captured) 0 count bytes sqlNanos copyNanos (steps captured)
      case next of
        Left failure -> pure (Left failure)
        Right (newCount, newBytes, newSqlNanos, newCopyNanos) -> go newCount newBytes newSqlNanos newCopyNanos rest

    runSteps _ _ _ count bytes sqlNanos copyNanos [] = pure (Right (count, bytes, sqlNanos, copyNanos))
    runSteps directory fixture stepNumber count bytes sqlNanos copyNanos (step : rest) =
      case step of
        CapturedSql {} -> do
          stepStart <- getMonotonicTimeNSec
          content <- readSqlStep directory step
          case content of
            Left failure -> pure (Left failure {fixture = Just fixture, stepIndex = Just stepNumber})
            Right sql -> do
              result <- query connection deadline Sql sql
              case result of
                Left problem -> pure (Left (nativeError ExecuteSql (Just fixture) (Just stepNumber) problem))
                Right () -> do
                  stepEnd <- getMonotonicTimeNSec
                  runSteps directory fixture (stepNumber + 1) (count + 1) (bytes + fromIntegral (ByteString.length sql)) (sqlNanos + stepEnd - stepStart) copyNanos rest
        CapturedCopy {} -> do
          stepStart <- getMonotonicTimeNSec
          let path = directory </> relativePath step
          copied <- copyCsv connection deadline path step
          case copied of
            Left problem -> pure (Left (nativeError ExecuteCopy (Just fixture) (Just stepNumber) problem))
            Right transferred -> do
              stepEnd <- getMonotonicTimeNSec
              runSteps directory fixture (stepNumber + 1) (count + 1) (bytes + transferred) sqlNanos (copyNanos + stepEnd - stepStart) rest

readSqlStep :: FilePath -> CapturedStep -> IO (Either LoadError ByteString.ByteString)
readSqlStep directory step = do
  let path = directory </> relativePath step
  readResult <- try @IOException $ withBinaryFile path ReadMode $ \handle ->
    ByteString.hGet handle (fromIntegral (byteLength step) + 1)
  pure $ case readResult of
    Left _ -> Left (simpleError VerifyBundle "SQL bundle file could not be read")
    Right bytes
      | fromIntegral (ByteString.length bytes) /= byteLength step -> Left (simpleError VerifyBundle "SQL bundle file changed")
      | hex (SHA256.hash bytes) /= contentDigest step -> Left (simpleError VerifyBundle "SQL bundle digest changed")
      | otherwise -> Right bytes

nativeError :: LoadPhase -> Maybe FixtureName -> Maybe Int -> NativeError -> LoadError
nativeError phase fixture stepIndex NativeError {sqlState, reason} =
  LoadError {phase, targetIdentity = Nothing, fixture, stepIndex, cause = reason, sqlState, cleanupFailure = Nothing}

simpleError :: LoadPhase -> Text -> LoadError
simpleError phase cause = LoadError {phase, targetIdentity = Nothing, fixture = Nothing, stepIndex = Nothing, cause, sqlState = Nothing, cleanupFailure = Nothing}

sessionError :: SessionError -> LoadError
sessionError failure = simpleError BeginLoad (Text.pack (show failure))

hex :: ByteString.ByteString -> Text
hex = Text.pack . concatMap digits . ByteString.unpack
  where
    digits byte = case showHex byte "" of
      [digit] -> ['0', digit]
      value -> value
