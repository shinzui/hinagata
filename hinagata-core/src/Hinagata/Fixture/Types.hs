module Hinagata.Fixture.Types
  ( FixtureName,
    fixtureNameText,
    mkFixtureName,
    FixtureDefinition (..),
    FixtureStep (..),
    CopySpec (..),
  )
where

import Data.Text qualified as Text
import Hinagata.Prelude

-- | A path component and stable fixture identity, not an arbitrary file path.
newtype FixtureName = FixtureName Text
  deriving stock (Eq, Ord, Show)

fixtureNameText :: FixtureName -> Text
fixtureNameText (FixtureName value) = value

mkFixtureName :: Text -> Either Text FixtureName
mkFixtureName value
  | Text.null value = Left "fixture name is empty"
  | Text.length value > 63 = Left "fixture name exceeds 63 characters"
  | Text.head value == '-' || Text.last value == '-' = Left "fixture name cannot start or end with '-':"
  | Text.all valid value = Right (FixtureName value)
  | otherwise = Left "fixture name must contain only lowercase ASCII letters, digits, and '-':"
  where
    valid character = (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-'

-- | Steps retain declaration order. Paths are validated and captured by the
-- bundle compiler before a plan becomes executable.
data FixtureStep
  = SqlFile !FilePath
  | CopyCsv !CopySpec
  deriving stock (Eq, Show, Generic)

data CopySpec = CopySpec
  { schema :: !Text,
    table :: !Text,
    columns :: ![Text],
    file :: !FilePath,
    header :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data FixtureDefinition = FixtureDefinition
  { name :: !FixtureName,
    includes :: ![FixtureName],
    steps :: ![FixtureStep]
  }
  deriving stock (Eq, Show, Generic)
