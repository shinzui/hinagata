-- | Shared private generation identity for lifecycle modules.
module Hinagata.Postgres.Internal.BaselineRef
  ( BaselineRef (..),
  )
where

import Hinagata.Connection (ConnectionTarget)
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
    baselinePlan :: !FixturePlan,
    cloneHook :: !(Maybe (ConnectionTarget -> IO (Either Text ())))
  }

instance Eq BaselineRef where
  left == right =
    (baselineName left, generationId left, baselineFingerprint left, clusterIdentity left, ownership left, baselinePlan left)
      == (baselineName right, generationId right, baselineFingerprint right, clusterIdentity right, ownership right, baselinePlan right)

instance Show BaselineRef where
  show reference = "BaselineRef " <> show (baselineName reference, generationId reference, baselineFingerprint reference, clusterIdentity reference, ownership reference, baselinePlan reference)
