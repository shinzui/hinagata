module Hinagata.Types
  ( DatabaseName,
    databaseNameText,
    mkDatabaseName,
    ProjectId,
    projectIdText,
    mkProjectId,
    RunId,
    runIdText,
    mkRunId,
    SqlIdentifier,
    sqlIdentifierText,
    mkSqlIdentifier,
    quoteSqlIdentifier,
    Port,
    portNumber,
    mkPort,
    Positive,
    positiveValue,
    mkPositive,
  )
where

import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Hinagata.Prelude

newtype DatabaseName = DatabaseName Text
  deriving stock (Eq, Ord, Show)

databaseNameText :: DatabaseName -> Text
databaseNameText (DatabaseName value) = value

mkDatabaseName :: Text -> Either Text DatabaseName
mkDatabaseName value = DatabaseName <$> validatePgIdentifier value

newtype SqlIdentifier = SqlIdentifier Text
  deriving stock (Eq, Ord, Show)

sqlIdentifierText :: SqlIdentifier -> Text
sqlIdentifierText (SqlIdentifier value) = value

mkSqlIdentifier :: Text -> Either Text SqlIdentifier
mkSqlIdentifier value = SqlIdentifier <$> validatePgIdentifier value

quoteSqlIdentifier :: SqlIdentifier -> Text
quoteSqlIdentifier (SqlIdentifier value) = "\"" <> Text.replace "\"" "\"\"" value <> "\""

validatePgIdentifier :: Text -> Either Text Text
validatePgIdentifier value
  | Text.null value = Left "PostgreSQL identifier is empty"
  | Text.any (== '\0') value = Left "PostgreSQL identifier contains NUL"
  | ByteString.length (Encoding.encodeUtf8 value) > 63 = Left "PostgreSQL identifier exceeds 63 UTF-8 bytes"
  | otherwise = Right value

newtype ProjectId = ProjectId Text
  deriving stock (Eq, Ord, Show)

projectIdText :: ProjectId -> Text
projectIdText (ProjectId value) = value

mkProjectId :: Text -> Either Text ProjectId
mkProjectId value = ProjectId <$> validateSlug "project ID" value

newtype RunId = RunId Text
  deriving stock (Eq, Ord, Show)

runIdText :: RunId -> Text
runIdText (RunId value) = value

mkRunId :: Text -> Either Text RunId
mkRunId value = RunId <$> validateSlug "run ID" value

validateSlug :: Text -> Text -> Either Text Text
validateSlug label value
  | Text.null value = Left (label <> " is empty")
  | Text.length value > 63 = Left (label <> " exceeds 63 characters")
  | Text.all valid value = Right value
  | otherwise = Left (label <> " must use lowercase ASCII letters, digits, '-' or '_'")
  where
    valid character = (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-' || character == '_'

newtype Port = Port Int
  deriving stock (Eq, Ord, Show)

portNumber :: Port -> Int
portNumber (Port value) = value

mkPort :: Int -> Either Text Port
mkPort value
  | value >= 1 && value <= 65535 = Right (Port value)
  | otherwise = Left "port must be between 1 and 65535"

newtype Positive = Positive Int
  deriving stock (Eq, Ord, Show)

positiveValue :: Positive -> Int
positiveValue (Positive value) = value

mkPositive :: Text -> Int -> Either Text Positive
mkPositive label value
  | value > 0 = Right (Positive value)
  | otherwise = Left (label <> " must be positive")
