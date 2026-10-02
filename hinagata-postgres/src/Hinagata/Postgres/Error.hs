-- | Secret-safe native session and load failures.
module Hinagata.Postgres.Error
  ( SessionError (..),
    NativePhase (..),
    NativeError (..),
    LoadPhase (..),
    LoadError (..),
  )
where

import Hinagata.Fixture.Types (FixtureName)
import Hinagata.Prelude

-- | Failure to open or exclusively use a Hinagata-owned session.
data SessionError
  = InvalidSessionOptions
  | ConnectionFailed !Text
  | ConnectionTimedOut !Text
  | SessionBusy
  | SessionClosed
  deriving stock (Eq, Show)

-- | Protocol stage that produced a private adapter failure.
data NativePhase = Connect | Begin | SetDeadline | Sql | Copy | Commit | Rollback
  deriving stock (Eq, Ord, Show)

-- | Server-provided messages may contain fixture data and are intentionally absent.
data NativeError = NativeError
  { phase :: !NativePhase,
    sqlState :: !(Maybe Text),
    reason :: !Text
  }
  deriving stock (Eq, Show)

-- | Stage at which an atomic fixture load failed.
data LoadPhase = VerifyBundle | BeginLoad | SetLoadDeadline | ExecuteSql | ExecuteCopy | CommitLoad | RollbackLoad
  deriving stock (Eq, Ord, Show)

-- | Secret-safe load failure. A failed or ambiguous COMMIT retires its session.
-- @cleanupFailure@ records a separate failure to roll back after the first error.
data LoadError = LoadError
  { phase :: !LoadPhase,
    targetIdentity :: !(Maybe Text),
    fixture :: !(Maybe FixtureName),
    stepIndex :: !(Maybe Int),
    cause :: !Text,
    sqlState :: !(Maybe Text),
    cleanupFailure :: !(Maybe Text)
  }
  deriving stock (Eq, Show)
