module Main (main) where

import Control.Monad (replicateM_, unless)
import Counter (addCounter)
import Data.Text qualified as Text
import Hinagata.Connection
import Hinagata.Types (mkDatabaseName, mkPort)
import Kiroku.Store qualified as Store
import System.Environment (getArgs, getEnv, lookupEnv)
import System.Exit (die)
import Text.Read (readMaybe)

main :: IO ()
main = do
  (counter, count) <-
    getArgs >>= \case
      [identifier, amount]
        | not (null identifier) && length identifier <= 32 && all (\c -> c >= 'a' && c <= 'z') identifier,
          Just count <- readMaybe amount,
          count > (0 :: Int) ->
            pure (Text.pack identifier, count)
      _ -> die "usage: hinagata-keiro-seed COUNTER POSITIVE-INCREMENT-COUNT"
  selectedHost <- Text.pack <$> getEnv "PGHOST"
  host <- require (if "/" `Text.isPrefixOf` selectedHost then socketDirectory selectedHost else tcpHost selectedHost)
  portText <- getEnv "PGPORT"
  port <- maybe (die "PGPORT must be a port number") (require . mkPort) (readMaybe portText)
  user <- Text.pack <$> getEnv "PGUSER"
  database <- require . mkDatabaseName . Text.pack =<< getEnv "PGDATABASE"
  target <- require (mkConnectionTarget host port user database Nothing)
  passwordFile <- lookupEnv "PGPASSFILE"
  -- Hasql's public connection-string settings pass this parameter to libpq;
  -- no password is copied to argv, output, or an ambient PGPASSWORD variable.
  let passfile = maybe "" (\path -> " passfile='" <> Text.concatMap escape (Text.pack path) <> "'") passwordFile
      connection = connectionStringText (renderConnectionString target) <> passfile
  Store.withStore (Store.defaultConnectionSettings connection) $ \store ->
    replicateM_ count (addCounter store counter >>= \accepted -> unless accepted (die "counter seed command failed"))
  where
    require = either (die . Text.unpack) pure
    escape character = if character == '\\' || character == '\'' then Text.pack ['\\', character] else Text.singleton character
