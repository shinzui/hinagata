-- | Shared private generation identity for lifecycle modules.
module Hinagata.Postgres.Internal.BaselineRef
  ( BaselineRef (..),
  )
where

import Hinagata.Fixture.Bundle (FixturePlan)
import Hinagata.Postgres.Ownership (CatalogIdentity, OwnedDatabase)
import Hinagata.Prelude
import Hinagata.Types (DatabaseName)

-- | Private identity of a sealed generation; the public API exposes this
-- type abstractly and only permits observing its database name.
data BaselineRef = BaselineRef
  { baselineName :: !DatabaseName,
    generationId :: !Text,
    baselineFingerprint :: !Text,
    clusterIdentity :: !CatalogIdentity,
    ownership :: !OwnedDatabase,
    baselinePlan :: !FixturePlan
  }
  deriving stock (Eq, Show)
