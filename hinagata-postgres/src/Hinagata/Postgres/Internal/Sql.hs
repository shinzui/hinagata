-- | SQL helpers used by the native loader.
module Hinagata.Postgres.Internal.Sql
  ( setLocalDeadlines,
  )
where

import Data.ByteString.Char8 qualified as ByteString
import Database.PostgreSQL.LibPQ qualified as PQ
import Hinagata.Postgres.Error
import Hinagata.Postgres.Internal.Libpq

setLocalDeadlines :: PQ.Connection -> SessionOptions -> Deadline -> IO (Either NativeError ())
setLocalDeadlines connection options deadline =
  query connection deadline SetDeadline $
    ByteString.pack
      ( "SET LOCAL statement_timeout = "
          ++ show (statementDeadlineMs options)
          ++ "; SET LOCAL lock_timeout = "
          ++ show (lockDeadlineMs options)
      )
