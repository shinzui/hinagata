-- | Explicit, versioned identities for service-owned hook inputs. Locations and
-- literal values deliberately have no diagnostic rendering.
module Hinagata.Hook.Revision
  ( InputName,
    mkInputName,
    inputNameText,
    RevisionInput (..),
    RevisionError (..),
    CapturedRevision,
    hookRevision,
    revisionInputLabels,
    validateRevisionInputs,
    deriveHookRevision,
    verifyHookRevisionInputs,
  )
where

import Control.Exception (IOException, bracket, bracketOnError, try)
import Control.Monad (unless)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as Bytes
import Data.ByteString.Builder (Builder, byteString, toLazyByteString, word64BE, word8)
import Data.List (sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Word (Word64)
import Numeric (showHex)
import System.Directory (makeAbsolute)
import System.IO (hClose)
import System.Posix.Files (getFdStatus, isRegularFile)
import System.Posix.IO (OpenFileFlags (..), OpenMode (ReadOnly), closeFd, defaultFileFlags, fdToHandle, openFd)

newtype InputName = InputName Text
  deriving stock (Eq, Ord, Show)

inputNameText :: InputName -> Text
inputNameText (InputName name) = name

mkInputName :: Text -> Either RevisionError InputName
mkInputName name
  | Just (first, _) <- Text.uncons name,
    lower first,
    Text.all allowed name,
    all (\part -> part /= "" && part /= "." && part /= "..") (Text.splitOn "/" name) =
      Right (InputName name)
  | otherwise = Left InvalidInputName
  where
    lower c = c >= 'a' && c <= 'z'
    allowed c = lower c || (c >= '0' && c <= '9') || c `elem` ("._-/" :: String)

data RevisionInput
  = FileInput !InputName !FilePath
  | ValueInput !InputName !Text

data RevisionError
  = InvalidInputName
  | EmptyInputs
  | DuplicateInput !InputName
  | InputUnreadable !InputName
  | InputsChanged !InputName
  deriving stock (Eq, Show)

data Evidence = FileEvidence !InputName !FilePath !Word64 !Bytes.ByteString | ValueEvidence !InputName !Text

data CapturedRevision = CapturedRevision !Text ![Evidence]

hookRevision :: CapturedRevision -> Text
hookRevision (CapturedRevision revision _) = revision

-- | Safe logical labels and kinds; never locations or selected values.
revisionInputLabels :: CapturedRevision -> [(InputName, Text)]
revisionInputLabels (CapturedRevision _ evidence) = map label evidence
  where
    label (FileEvidence name _ _ _) = (name, "file")
    label (ValueEvidence name _) = (name, "value")

inputName :: RevisionInput -> InputName
inputName (FileInput name _) = name
inputName (ValueInput name _) = name

validateRevisionInputs :: [RevisionInput] -> Either RevisionError ()
validateRevisionInputs [] = Left EmptyInputs
validateRevisionInputs inputs = go Set.empty inputs
  where
    go _ [] = Right ()
    go seen (input : rest)
      | Set.member name seen = Left (DuplicateInput name)
      | otherwise = go (Set.insert name seen) rest
      where
        name = inputName input

deriveHookRevision :: [RevisionInput] -> IO (Either RevisionError CapturedRevision)
deriveHookRevision inputs = case validateRevisionInputs inputs of
  Left failure -> pure (Left failure)
  Right () -> do
    captured <- traverse capture (sortOn (Encoding.encodeUtf8 . inputNameText . inputName) inputs)
    pure $ do
      evidence <- sequence captured
      let encoding = byteString "hinagata-hook-revision-v1\0" <> word64BE (fromIntegral (length evidence)) <> foldMap encode evidence
          digest = SHA256.hashlazy (toLazyByteString encoding)
          hex = Text.pack (concatMap (\byte -> let value = showHex byte "" in if length value == 1 then '0' : value else value) (Bytes.unpack digest))
      Right (CapturedRevision ("hinagata-hook-revision-v1:sha256:" <> hex) evidence)

capture :: RevisionInput -> IO (Either RevisionError Evidence)
capture (ValueInput name value) = pure (Right (ValueEvidence name value))
capture (FileInput name path) = do
  result <- try @IOException $ do
    unless (not (null path) && '\0' `notElem` path) (ioError (userError "invalid input location"))
    absolute <- makeAbsolute path
    (size, digest) <- hashFile absolute
    pure (FileEvidence name absolute size digest)
  pure (either (const (Left (InputUnreadable name))) Right result)

-- Open nonblocking, then inspect the opened descriptor, so a pipe (including a
-- symlink to one or a path replaced during open) cannot block preparation.
hashFile :: FilePath -> IO (Word64, Bytes.ByteString)
hashFile path = bracket acquire hClose (\handle -> loop handle 0 SHA256.init)
  where
    acquire = bracketOnError (openFd path ReadOnly defaultFileFlags {nonBlock = True}) closeFd $ \fd -> do
      status <- getFdStatus fd
      unless (isRegularFile status) (ioError (userError "input is not regular"))
      fdToHandle fd
    loop handle count context = do
      bytes <- Bytes.hGet handle 65536
      if Bytes.null bytes
        then pure (count, SHA256.finalize context)
        else do
          let next = SHA256.update context bytes
              total = count + fromIntegral (Bytes.length bytes)
          next `seq` total `seq` loop handle total next

encode :: Evidence -> Builder
encode (FileEvidence name _ size digest) = sized (Encoding.encodeUtf8 (inputNameText name)) <> word8 1 <> word64BE size <> byteString digest
encode (ValueEvidence name value) = sized (Encoding.encodeUtf8 (inputNameText name)) <> word8 2 <> sized (Encoding.encodeUtf8 value)

sized :: Bytes.ByteString -> Builder
sized bytes = word64BE (fromIntegral (Bytes.length bytes)) <> byteString bytes

-- | Re-resolve every selected file, including symlinks, and compare its bytes.
-- This checks boundaries; callers must keep inputs stable throughout execution.
verifyHookRevisionInputs :: CapturedRevision -> IO (Either RevisionError ())
verifyHookRevisionInputs (CapturedRevision _ evidence) = go evidence
  where
    go [] = pure (Right ())
    go (ValueEvidence {} : rest) = go rest
    go (FileEvidence name path size digest : rest) = do
      result <- try @IOException (hashFile path)
      case result of
        Right current | current == (size, digest) -> go rest
        _ -> pure (Left (InputsChanged name))
