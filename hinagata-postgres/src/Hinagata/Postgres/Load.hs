-- | Atomic direct loading into a caller-selected, already migrated database.
module Hinagata.Postgres.Load
  ( LoadReport (..),
    loadPlan,
    loadInto,
  )
where

import Hinagata.Postgres.Internal.Load (LoadReport (..), loadInto, loadPlan)
