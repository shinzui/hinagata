-- | Bounded validation admission and command-wide cancellation.
module Hinagata.Cli.Validation (cancelledError, validateBatches) where

import Control.Concurrent.Async qualified as Async
import Control.Exception qualified
import Data.Text qualified as Text
import Hinagata.Cli.Output (CliError (..), ValidationResult (..))
import Hinagata.Cli.Process (CancellationScope, CommandCancelled (..), cancellationSignal, waitCancellation, withCooperativeCancellation)

cancelledError :: Int -> CliError
cancelledError signal = CliError "command" "command_cancelled" "command cancelled before completion" Nothing Nothing Nothing Nothing (128 + signal) Nothing Nothing

-- | A worker is joined even after cancellation. Its typed preparation result
-- takes precedence over a generic cancellation; completed results are retained.
validateBatches :: CancellationScope -> Int -> (Text.Text -> IO ValidationResult) -> [Text.Text] -> IO [ValidationResult]
validateBatches scope size validate names = withCooperativeCancellation scope (go (chunksOf size names))
  where
    cancelled name signal = ValidationResult name (Left (cancelledError signal))
    run name = Async.withAsync (validate name) $ \worker -> do
      raced <- Async.race (Async.waitCatch worker) (waitCancellation scope)
      result <- case raced of
        Left completed -> pure completed
        Right signal -> do
          Async.cancelWith worker (CommandCancelled signal)
          Async.waitCatch worker
      case result of
        Right value -> pure value
        Left exception -> case Control.Exception.fromException exception of
          Just (CommandCancelled signal) -> pure (cancelled name signal)
          Nothing -> Control.Exception.throwIO exception
    go [] = pure []
    go (batch : pending) = do
      signal <- cancellationSignal scope
      case signal of
        Just number -> pure (map (\name -> cancelled name number) (concat (batch : pending)))
        Nothing -> do
          results <- Async.mapConcurrently run batch
          rest <- go pending
          pure (results <> rest)

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf size values = let (first, rest) = splitAt size values in first : chunksOf size rest
