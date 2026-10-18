-- | Secret-safe native session and load failures.
module Hinagata.Postgres.Error
  ( SessionError (..),
    NativePhase (..),
    NativeError (..),
    LoadPhase (..),
    LoadError (..),
    FixtureLoadContext (..),
    loadErrorContext,
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

-- | Safe fixture failure context for lifecycle APIs. Endpoint identity and raw
-- server messages are deliberately excluded. Rollback is independent of clone
-- release, which the enclosing lifecycle error reports separately.
data FixtureLoadContext = FixtureLoadContext
  { phase :: !LoadPhase,
    fixture :: !(Maybe FixtureName),
    stepIndex :: !(Maybe Int),
    sqlState :: !(Maybe Text),
    cause :: !Text,
    rollbackFailure :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

loadErrorContext :: LoadError -> FixtureLoadContext
loadErrorContext LoadError {phase, fixture, stepIndex, sqlState, cause, cleanupFailure} =
  FixtureLoadContext {phase, fixture, stepIndex, sqlState, cause, rollbackFailure = cleanupFailure}
