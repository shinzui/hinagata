-- | Bracketed, exclusive libpq sessions for Hinagata operations.
module Hinagata.Postgres.Session
  ( Session,
    SessionOptions (..),
    defaultSessionOptions,
    withSession,
  )
where

import Hinagata.Postgres.Internal.Libpq
