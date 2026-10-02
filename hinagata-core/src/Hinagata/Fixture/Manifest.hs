module Hinagata.Fixture.Manifest
  ( ManifestError (..),
    FixtureManifest,
    decodeManifest,
    manifestDefinition,
    manifestDescription,
    implicitDefinition,
  )
where

import Data.Aeson (Value (..), (.:), (.:?))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither, withObject)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Yaml qualified as Yaml
import Hinagata.Fixture.Types
import Hinagata.Prelude
import Hinagata.Types
import System.FilePath (isAbsolute)

data ManifestError
  = InvalidYaml !Text
  | InvalidManifest !Text
  deriving stock (Eq, Show)

data FixtureManifest = FixtureManifest
  { name :: !FixtureName,
    description :: !(Maybe Text),
    includes :: ![FixtureName],
    steps :: ![FixtureStep]
  }
  deriving stock (Eq, Show, Generic)

-- | Decode an explicit fixture.yaml. Its name must match the directory name.
-- The caller still validates filesystem paths and captures bytes before use.
decodeManifest :: FixtureName -> ByteString -> Either ManifestError FixtureManifest
decodeManifest expected bytes = do
  value <- either (Left . InvalidYaml . Text.pack . show) Right (Yaml.decodeEither' bytes)
  parsed <- either (Left . InvalidManifest . Text.pack) Right (parseEither parseManifest value)
  let FixtureManifest {name = actualName} = parsed
  if actualName == expected
    then Right parsed
    else Left (InvalidManifest "manifest name does not match fixture directory")

manifestDefinition :: FixtureManifest -> FixtureDefinition
manifestDefinition FixtureManifest {name, includes, steps} = FixtureDefinition {name, includes, steps}

manifestDescription :: FixtureManifest -> Maybe Text
manifestDescription FixtureManifest {description} = description

-- | A directory without fixture.yaml has exactly one conventional SQL step.
implicitDefinition :: FixtureName -> FixtureDefinition
implicitDefinition name = FixtureDefinition {name, includes = [], steps = [SqlFile "fixture.sql"]}

parseManifest :: Value -> Parser FixtureManifest
parseManifest = withObject "fixture manifest" $ \object -> do
  rejectUnknown ["name", "description", "include", "steps"] object
  nameText <- object .: "name"
  name <- either (fail . Text.unpack) pure (mkFixtureName nameText)
  description <- object .:? "description"
  includeNames <- fromMaybe [] <$> object .:? "include"
  includes <- traverse (either (fail . Text.unpack) pure . mkFixtureName) includeNames
  rawSteps <- object .: "steps"
  steps <- case rawSteps of
    [] -> fail "steps must be non-empty"
    values -> traverse parseStep values
  pure FixtureManifest {name, description, includes, steps}

parseStep :: Value -> Parser FixtureStep
parseStep = withObject "fixture step" $ \object -> do
  rejectUnknown ["sql", "copy"] object
  case (KeyMap.lookup "sql" object, KeyMap.lookup "copy" object) of
    (Just (String path), Nothing) -> SqlFile <$> safePath path
    (Nothing, Just value) -> CopyCsv <$> parseCopy value
    _ -> fail "step must contain exactly one of sql or copy"

parseCopy :: Value -> Parser CopySpec
parseCopy = withObject "copy step" $ \object -> do
  rejectUnknown ["table", "columns", "file", "format", "header"] object
  tableValue <- object .: "table"
  (schema, table) <- parseTable tableValue
  columnNames <- object .: "columns"
  columns <- case columnNames of
    [] -> fail "COPY columns must be non-empty"
    values -> traverse identifier values
  fileText <- object .: "file"
  file <- safePath fileText
  format <- object .: "format"
  unless (format == ("csv" :: Text)) (fail "COPY format must be csv")
  header <- object .: "header"
  pure CopySpec {schema, table, columns, file, header}

parseTable :: Value -> Parser (SqlIdentifier, SqlIdentifier)
parseTable = withObject "COPY table" $ \object -> do
  rejectUnknown ["schema", "name"] object
  schema <- object .: "schema" >>= identifier
  table <- object .: "name" >>= identifier
  pure (schema, table)

identifier :: Text -> Parser SqlIdentifier
identifier = either (fail . Text.unpack) pure . mkSqlIdentifier

safePath :: Text -> Parser FilePath
safePath raw = do
  let path = Text.unpack raw
  when (Text.null raw || Text.any (== '\0') raw || isAbsolute path || any (`elem` [".", "..", ""]) (Text.splitOn "/" raw)) $
    fail "step path must be a non-empty relative path without . or .. components"
  pure path

rejectUnknown :: [Text] -> KeyMap.KeyMap Value -> Parser ()
rejectUnknown allowed object =
  case filter (`notElem` allowed) (map Key.toText (KeyMap.keys object)) of
    [] -> pure ()
    unknown -> fail ("unknown fields: " ++ Text.unpack (Text.intercalate ", " unknown))
