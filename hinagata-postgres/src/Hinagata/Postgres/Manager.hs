-- | Manager-local admission for active clones and setup workers.
module Hinagata.Postgres.Manager
  ( Manager,
    DatabaseRequest (..),
    withManager,
    withManagedDatabase,
    withDatabases,
  )
where

import Control.Concurrent.MVar
import Control.Exception (bracket, finally, mask, onException)
import Data.Foldable (traverse_)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Hinagata.Config
import Hinagata.Fixture.Bundle (FixturePlan)
import Hinagata.Postgres.Baseline (BaselineRef)
import Hinagata.Postgres.Lease (LeaseError (..), LeaseInfo, withDatabase)
import Hinagata.Prelude
import Hinagata.Types (mkPositive, positiveValue)
import System.Timeout (timeout)

-- | A scoped, local admission controller. It does not enforce a cluster-wide
-- connection budget; callers must allow for other managers and service pools.
data Manager = Manager
  { configuration :: !HinagataConfig,
    activeGate :: !Gate,
    setupGate :: !Gate
  }

-- | One named clone request. Names must be unique within a collection.
data DatabaseRequest = DatabaseRequest
  { requestName :: !Text,
    baseline :: !BaselineRef,
    scenario :: !FixturePlan
  }

data Gate = Gate
  { limit :: !Int,
    pendingLimit :: !Int,
    state :: !(MVar GateState)
  }

data Waiter = Waiter
  { ticket :: !Int,
    requested :: !Int,
    signal :: !(MVar Bool)
  }

data GateState = GateState
  { used :: !Int,
    queued :: ![Waiter],
    granted :: ![(Int, Int)],
    nextTicket :: !Int,
    closed :: !Bool
  }

data Admission = Immediate | Queued !Int !(MVar Bool)

-- | Bracket manager-local capacity. Closing a manager wakes queued callers
-- with a typed error; callers must finish active callbacks before scope exit.
withManager :: HinagataConfig -> (Manager -> IO a) -> IO a
withManager configuration = bracket create closeManager
  where
    create = do
      activeGate <- newGate (positiveValue (activeLeases configuration)) (positiveValue (pendingRequests configuration))
      setupGate <- newGate (positiveValue (setupWorkers configuration)) (positiveValue (activeLeases configuration))
      pure Manager {configuration, activeGate, setupGate}

-- | Reserve one active slot, then a setup worker until callback handoff.
-- Queue saturation is reported before allocating any database.
withManagedDatabase :: Manager -> BaselineRef -> FixturePlan -> (LeaseInfo -> IO a) -> IO (Either LeaseError a)
withManagedDatabase manager baseline scenario callback = do
  expiry <- acquisitionExpiry manager
  withPermitUntil (activeGate manager) 1 expiry (withSetupUntil manager expiry baseline scenario callback)

-- | Reserve capacity for the whole named set, acquire in name order, and
-- unwind earlier clones if any later acquisition fails. The callback receives
-- names paired with application endpoints in that same stable order.
withDatabases :: Manager -> NonEmpty DatabaseRequest -> ([(Text, LeaseInfo)] -> IO a) -> IO (Either LeaseError a)
withDatabases manager requests callback = do
  let ordered = sortOn requestName (NonEmpty.toList requests)
      count = length ordered
  if any (Text.null . requestName) ordered || duplicateNames ordered
    then pure (Left (admissionError "database request names must be nonempty and unique"))
    else do
      expiry <- acquisitionExpiry manager
      withPermitUntil (activeGate manager) count expiry (acquireAll expiry ordered [] callback)
  where
    acquireAll _ [] accumulated callbackAction = Right <$> callbackAction (reverse accumulated)
    acquireAll expiry (DatabaseRequest {requestName, baseline, scenario} : rest) accumulated callbackAction = do
      result <- withSetupUntil manager expiry baseline scenario (\info -> acquireAll expiry rest ((requestName, info) : accumulated) callbackAction)
      pure (result >>= id)

    duplicateNames (left : right : rest) = requestName left == requestName right || duplicateNames (right : rest)
    duplicateNames _ = False

withSetupUntil :: Manager -> Word64 -> BaselineRef -> FixturePlan -> (LeaseInfo -> IO a) -> IO (Either LeaseError a)
withSetupUntil Manager {configuration, setupGate} expiry baseline scenario callback = mask $ \restore -> do
  admitted <- acquireUntil setupGate 1 expiry
  case admitted of
    Left problem -> pure (Left problem)
    Right () -> do
      released <- newIORef False
      let releaseOnce = do
            shouldRelease <- atomicModifyIORef' released (\done -> (True, not done))
            when shouldRelease (releaseGate setupGate 1)
      remaining <- remainingMs expiry
      case remaining of
        Nothing -> releaseOnce >> pure (Left (admissionError "acquisition deadline expired during setup admission"))
        Just milliseconds -> case mkPositive "acquisition deadline" milliseconds of
          Left _ -> releaseOnce >> pure (Left (admissionError "acquisition deadline is invalid"))
          Right budget ->
            restore (withDatabase configuration {acquisitionDeadlineMs = budget} baseline scenario (\info -> releaseOnce >> callback info)) `finally` releaseOnce

withPermitUntil :: Gate -> Int -> Word64 -> IO (Either LeaseError a) -> IO (Either LeaseError a)
withPermitUntil gate amount expiry action = mask $ \restore -> do
  admitted <- acquireUntil gate amount expiry
  case admitted of
    Left problem -> pure (Left problem)
    Right () -> restore action `finally` releaseGate gate amount

acquisitionExpiry :: Manager -> IO Word64
acquisitionExpiry Manager {configuration} = do
  now <- getMonotonicTimeNSec
  pure (now + fromIntegral (positiveValue (acquisitionDeadlineMs configuration)) * 1000000)

remainingMs :: Word64 -> IO (Maybe Int)
remainingMs expiry = do
  now <- getMonotonicTimeNSec
  pure $ if now >= expiry then Nothing else Just (fromIntegral ((expiry - now) `div` 1000000) `max` 1)

acquireUntil :: Gate -> Int -> Word64 -> IO (Either LeaseError ())
acquireUntil gate amount expiry = do
  now <- getMonotonicTimeNSec
  if now >= expiry
    then pure (Left (admissionError "acquisition deadline expired"))
    else do
      let microseconds = fromIntegral (min (fromIntegral (maxBound :: Int)) ((expiry - now) `div` 1000))
      outcome <- timeout (max 1 microseconds) (acquireGate gate amount)
      pure (fromMaybe (Left (admissionError "acquisition deadline expired while queued")) outcome)

newGate :: Int -> Int -> IO Gate
newGate limit pendingLimit = do
  state <- newMVar GateState {used = 0, queued = [], granted = [], nextTicket = 0, closed = False}
  pure Gate {limit, pendingLimit, state}

acquireGate :: Gate -> Int -> IO (Either LeaseError ())
acquireGate gate amount = mask $ \restore -> do
  signal <- newEmptyMVar
  decision <- modifyMVar (state gate) $ \current ->
    if closed current
      then pure (current, Left (admissionError "manager is closed"))
      else
        if amount > limit gate
          then pure (current, Left (admissionError "collection exceeds the active-lease limit"))
          else
            if null (queued current) && used current + amount <= limit gate
              then pure (current {used = used current + amount}, Right Immediate)
              else
                if length (queued current) >= pendingLimit gate
                  then pure (current, Left (admissionError "manager pending-request limit is full"))
                  else do
                    let identifier = nextTicket current
                        waiter = Waiter identifier amount signal
                    pure (current {queued = queued current ++ [waiter], nextTicket = identifier + 1}, Right (Queued identifier signal))
  case decision of
    Left problem -> pure (Left problem)
    Right Immediate -> pure (Right ())
    Right (Queued identifier waiting) -> do
      accepted <- restore (takeMVar waiting) `onException` cancelWaiter gate identifier
      if accepted
        then acknowledge gate identifier >> pure (Right ())
        else pure (Left (admissionError "manager closed while request was queued"))

acknowledge :: Gate -> Int -> IO ()
acknowledge gate identifier = modifyMVar_ (state gate) $ \current ->
  pure current {granted = filter ((/= identifier) . fst) (granted current)}

cancelWaiter :: Gate -> Int -> IO ()
cancelWaiter gate identifier = modifyMVar_ (state gate) $ \current -> do
  let waiting = filter ((/= identifier) . ticket) (queued current)
      reserved = lookup identifier (granted current)
      withoutGrant = filter ((/= identifier) . fst) (granted current)
      released = current {queued = waiting, granted = withoutGrant, used = used current - maybe 0 id reserved}
  wake gate released

releaseGate :: Gate -> Int -> IO ()
releaseGate gate amount = modifyMVar_ (state gate) $ \current ->
  wake gate current {used = used current - amount}

wake :: Gate -> GateState -> IO GateState
wake gate current = case queued current of
  [] -> pure current
  waiter : rest
    | used current + requested waiter <= limit gate && not (closed current) -> do
        putMVar (signal waiter) True
        wake gate current {used = used current + requested waiter, queued = rest, granted = (ticket waiter, requested waiter) : granted current}
    | otherwise -> pure current

closeManager :: Manager -> IO ()
closeManager Manager {activeGate, setupGate} = closeGate activeGate >> closeGate setupGate

closeGate :: Gate -> IO ()
closeGate gate = modifyMVar_ (state gate) $ \current -> do
  traverse_ (\waiter -> putMVar (signal waiter) False) (queued current)
  pure current {queued = [], closed = True}

admissionError :: Text -> LeaseError
admissionError cause = LeaseError cause Nothing Nothing
