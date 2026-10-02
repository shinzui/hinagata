-- | Shared location and operation context for typed diagnostics.
-- Backend and command-line errors remain in their owning packages.
module Hinagata.Error
  ( DiagnosticContext (..),
    diagnosticContext,
  )
where

import Hinagata.Fixture.Types (FixtureName)
import Hinagata.Prelude

data DiagnosticContext = DiagnosticContext
  { operation :: !Text,
    fixture :: !(Maybe FixtureName),
    sourcePath :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show)

diagnosticContext :: Text -> DiagnosticContext
diagnosticContext operation = DiagnosticContext {operation, fixture = Nothing, sourcePath = Nothing}
