module Hinagata.Fixture.SqlPolicy
  ( SqlPolicyError (..),
    checkSqlPolicy,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString
import Data.Char (toLower)
import Data.List (isPrefixOf)
import Data.Text qualified as Text
import Hinagata.Prelude

data SqlPolicyError
  = ForbiddenStatement !Text
  | PsqlCommand
  | UnterminatedSqlLiteral !Text
  | SqlContainsNul
  deriving stock (Eq, Show)

data Prefix = AfterStart | AfterPrepare
  deriving stock (Eq, Show)

-- | A lexical policy check for trusted SQL, not a PostgreSQL parser. The
-- caller executes the original bytes unchanged after this preflight.
checkSqlPolicy :: ByteString -> Either SqlPolicyError ()
checkSqlPolicy bytes
  | ByteString.elem '\0' bytes = Left SqlContainsNul
  | otherwise = scan True True Nothing (ByteString.unpack bytes)

scan :: Bool -> Bool -> Maybe Prefix -> String -> Either SqlPolicyError ()
scan _ _ _ [] = Right ()
scan statementStart lineStart prefix input@(character : rest)
  | character == '\n' = scan statementStart True prefix rest
  | character == ' ' || character == '\t' || character == '\r' = scan statementStart lineStart prefix rest
  | "--" `isPrefixOf` input = scan statementStart True prefix (dropLine (drop 2 input))
  | "/*" `isPrefixOf` input = do
      (remaining, nextLineStart) <- dropBlock 1 lineStart (drop 2 input)
      scan statementStart nextLineStart prefix remaining
  | character == '\\' && lineStart = Left PsqlCommand
  | character == ';' = scan True False Nothing rest
  | character == '\'' = do
      remaining <- dropSingle False rest
      scan False False Nothing remaining
  | character == '"' = do
      remaining <- dropDouble rest
      scan False False Nothing remaining
  | character == '$',
    Just (delimiter, afterOpen) <- dollarOpen input = do
      remaining <- dropDollar delimiter afterOpen
      scan False False Nothing remaining
  | identifierStart character =
      let (word, remaining) = span identifierContinue input
       in case remaining of
            '\'' : afterOpen | map toLower word == "e" -> do
              afterClose <- dropSingle True afterOpen
              scan False False Nothing afterClose
            _ -> case classify statementStart prefix (map toLower word) of
              Left failure -> Left failure
              Right (nextStart, nextPrefix) -> scan nextStart False nextPrefix remaining
  | otherwise = scan False False Nothing rest

classify :: Bool -> Maybe Prefix -> String -> Either SqlPolicyError (Bool, Maybe Prefix)
classify _ (Just _) "transaction" = Left (ForbiddenStatement "TRANSACTION")
classify _ (Just _) _ = Right (False, Nothing)
classify False Nothing _ = Right (False, Nothing)
classify True Nothing word
  | word `elem` ["begin", "commit", "end", "rollback", "abort", "savepoint", "release", "copy"] =
      Left (ForbiddenStatement (Text.pack word))
  | word == "start" = Right (False, Just AfterStart)
  | word == "prepare" = Right (False, Just AfterPrepare)
  | otherwise = Right (False, Nothing)

identifierStart :: Char -> Bool
identifierStart character = asciiLetter character || character == '_'

identifierContinue :: Char -> Bool
identifierContinue character = identifierStart character || (character >= '0' && character <= '9') || character == '$'

asciiLetter :: Char -> Bool
asciiLetter character = (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z')

dropLine :: String -> String
dropLine [] = []
dropLine ('\n' : rest) = rest
dropLine (_ : rest) = dropLine rest

dropBlock :: Int -> Bool -> String -> Either SqlPolicyError (String, Bool)
dropBlock _ _ [] = Left (UnterminatedSqlLiteral "block comment")
dropBlock depth lineStart input
  | "/*" `isPrefixOf` input = dropBlock (depth + 1) lineStart (drop 2 input)
  | "*/" `isPrefixOf` input =
      if depth == 1
        then Right (drop 2 input, lineStart)
        else dropBlock (depth - 1) lineStart (drop 2 input)
  | otherwise = case input of
      '\n' : rest -> dropBlock depth True rest
      _ : rest -> dropBlock depth lineStart rest

dropSingle :: Bool -> String -> Either SqlPolicyError String
dropSingle _ [] = Left (UnterminatedSqlLiteral "single-quoted string")
dropSingle escaped ('\\' : _ : rest) | escaped = dropSingle escaped rest
dropSingle escaped ('\'' : '\'' : rest) = dropSingle escaped rest
dropSingle _ ('\'' : rest) = Right rest
dropSingle escaped (_ : rest) = dropSingle escaped rest

dropDouble :: String -> Either SqlPolicyError String
dropDouble [] = Left (UnterminatedSqlLiteral "quoted identifier")
dropDouble ('"' : '"' : rest) = dropDouble rest
dropDouble ('"' : rest) = Right rest
dropDouble (_ : rest) = dropDouble rest

dollarOpen :: String -> Maybe (String, String)
dollarOpen ('$' : rest) =
  let (tag, afterTag) = span (\character -> asciiLetter character || (character >= '0' && character <= '9') || character == '_') rest
      validTag = case tag of
        [] -> True
        first : _ -> identifierStart first
   in case afterTag of
        '$' : body | validTag -> Just ('$' : tag ++ "$", body)
        _ -> Nothing
dollarOpen _ = Nothing

dropDollar :: String -> String -> Either SqlPolicyError String
dropDollar _ [] = Left (UnterminatedSqlLiteral "dollar-quoted string")
dropDollar delimiter input
  | delimiter `isPrefixOf` input = Right (drop (length delimiter) input)
  | otherwise = dropDollar delimiter (drop 1 input)
