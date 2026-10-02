module Hinagata.Fixture.Bundle
  ( BundleConfig (..),
    BundleError (..),
    CapturedStep (..),
    CapturedFixture (..),
    FixturePlan,
    planDigest,
    planDirectory,
    planFixtures,
    compileFixtures,
    CompositionError (..),
    CapturedFixtureRef (..),
    ComposedPlan (..),
    composePlans,
  )
where

import Control.Exception (IOException, try)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder (Builder, byteString, toLazyByteString, word64BE, word8)
import Data.ByteString.Lazy qualified as Lazy
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Word (Word64)
import Hinagata.Fixture.Graph (GraphError, resolveFixtures)
import Hinagata.Fixture.Manifest
import Hinagata.Fixture.SqlPolicy
import Hinagata.Fixture.Types
import Hinagata.Prelude
import Hinagata.Types
import Numeric (showHex)
import System.Directory
  ( canonicalizePath,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getFileSize,
    getModificationTime,
    pathIsSymbolicLink,
    renameDirectory,
  )
import System.FilePath (isAbsolute, makeRelative, takeFileName, (</>))
import System.IO (Handle, IOMode (..), withBinaryFile)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withTempDirectory)

data BundleConfig = BundleConfig
  { fixtureRoot :: !FilePath,
    bundleRoot :: !FilePath,
    sqlSizeLimit :: !Positive,
    chunkSize :: !Positive
  }
  deriving stock (Eq, Show)

data BundleError
  = BundleIo !Text
  | MissingFixture !FixtureName
  | UnsafePath !FilePath
  | InvalidFixtureManifest !FixtureName !ManifestError
  | InvalidFixtureGraph !GraphError
  | SourceChanged !FilePath
  | SqlStepTooLarge !FilePath
  | InvalidSql !FilePath !SqlPolicyError
  deriving stock (Eq, Show)

data CapturedStep
  = CapturedSql
      { relativePath :: !FilePath,
        contentDigest :: !Text,
        byteLength :: !Word64
      }
  | CapturedCopy
      { copySpec :: !CopySpec,
        relativePath :: !FilePath,
        contentDigest :: !Text,
        byteLength :: !Word64
      }
  deriving stock (Eq, Show)

data CapturedFixture = CapturedFixture
  { name :: !FixtureName,
    includes :: ![FixtureName],
    steps :: ![CapturedStep],
    identity :: !Text
  }
  deriving stock (Eq, Show)

data FixturePlan = FixturePlan
  { directory :: !FilePath,
    digest :: !Text,
    fixtures :: ![CapturedFixture]
  }
  deriving stock (Eq, Show)

planDigest :: FixturePlan -> Text
planDigest FixturePlan {digest} = digest

planDirectory :: FixturePlan -> FilePath
planDirectory FixturePlan {directory} = directory

planFixtures :: FixturePlan -> [CapturedFixture]
planFixtures FixturePlan {fixtures} = fixtures

data CompositionError = ConflictingFixture !FixtureName
  deriving stock (Eq, Show)

data CapturedFixtureRef = CapturedFixtureRef
  { directory :: !FilePath,
    fixture :: !CapturedFixture
  }
  deriving stock (Eq, Show)

data ComposedPlan = ComposedPlan
  { basePrefix :: ![CapturedFixtureRef],
    scenarioRemainder :: ![CapturedFixtureRef]
  }
  deriving stock (Eq, Show)

-- | Purely compare frozen fixture identities and remove a verified-equal
-- overlap from the scenario. Only the lifecycle manager can authorize skipping
-- the base prefix on a clone of its sealed baseline.
composePlans :: FixturePlan -> FixturePlan -> Either CompositionError ComposedPlan
composePlans base scenario = do
  remainder <- traverse select (planFixtures scenario)
  pure
    ComposedPlan
      { basePrefix = map (CapturedFixtureRef (planDirectory base)) (planFixtures base),
        scenarioRemainder = [reference | Just reference <- remainder]
      }
  where
    baseIdentities = Map.fromList [(fixtureName, fixtureIdentity) | CapturedFixture {name = fixtureName, identity = fixtureIdentity} <- planFixtures base]
    select fixture@CapturedFixture {name = fixtureName, identity = fixtureIdentity} =
      case Map.lookup fixtureName baseIdentities of
        Nothing -> Right (Just (CapturedFixtureRef (planDirectory scenario) fixture))
        Just baseIdentity
          | baseIdentity == fixtureIdentity -> Right Nothing
          | otherwise -> Left (ConflictingFixture fixtureName)

compileFixtures :: BundleConfig -> [FixtureName] -> IO (Either BundleError FixturePlan)
compileFixtures config roots = do
  outcome <- try @IOException $ do
    root <- canonicalizePath (fixtureRoot config)
    validRoot <- doesDirectoryExist root
    if not validRoot
      then pure (Left (BundleIo "fixture root is not a directory"))
      else do
        createDirectoryIfMissing True (bundleRoot config)
        withTempDirectory (bundleRoot config) "hinagata-capture-" $ \staging ->
          runExceptT $ do
            definitions <- discover root roots
            ordered <- either (throwE . InvalidFixtureGraph) pure (resolveFixtures definitions roots)
            captured <- captureAll config root staging ordered
            let digest = hashBuilder (planEncoding captured)
                manifest = strictBuilder (manifestEncoding digest captured)
            lift (ByteString.writeFile (staging </> "manifest.bin") manifest)
            published <- lift (publish (bundleRoot config) staging digest manifest captured)
            pure FixturePlan {directory = published, digest, fixtures = captured}
  pure $ either (Left . BundleIo . Text.pack . show) id outcome

discover :: FilePath -> [FixtureName] -> ExceptT BundleError IO [FixtureDefinition]
discover root = go Set.empty []
  where
    go _ found [] = pure (reverse found)
    go seen found (next : rest)
      | Set.member next seen = go seen found rest
      | otherwise = do
          definition <- loadDefinition root next
          let FixtureDefinition {includes = dependencies} = definition
          go (Set.insert next seen) (definition : found) (dependencies ++ rest)

loadDefinition :: FilePath -> FixtureName -> ExceptT BundleError IO FixtureDefinition
loadDefinition root fixtureName = do
  let directory = root </> Text.unpack (fixtureNameText fixtureName)
  exists <- lift (doesDirectoryExist directory)
  unless exists (throwE (MissingFixture fixtureName))
  canonicalDirectory <- lift (canonicalizePath directory)
  unless (within root canonicalDirectory) (throwE (UnsafePath directory))
  let manifestPath = canonicalDirectory </> "fixture.yaml"
  hasManifest <- lift (doesFileExist manifestPath)
  manifestIsLink <- lift $ do
    linkResult <- try @IOException (pathIsSymbolicLink manifestPath)
    case linkResult of
      Right linked -> pure linked
      Left failure | isDoesNotExistError failure -> pure False
      Left failure -> ioError failure
  if hasManifest || manifestIsLink
    then do
      canonicalManifest <- lift (canonicalizePath manifestPath)
      unless (within root canonicalManifest) (throwE (UnsafePath manifestPath))
      validManifest <- lift (doesFileExist canonicalManifest)
      unless validManifest (throwE (UnsafePath manifestPath))
      bytes <- lift (ByteString.readFile canonicalManifest)
      either (throwE . InvalidFixtureManifest fixtureName) (pure . manifestDefinition) (decodeManifest fixtureName bytes)
    else pure (implicitDefinition fixtureName)

captureAll :: BundleConfig -> FilePath -> FilePath -> [FixtureDefinition] -> ExceptT BundleError IO [CapturedFixture]
captureAll config root staging = go 0
  where
    go :: Int -> [FixtureDefinition] -> ExceptT BundleError IO [CapturedFixture]
    go _ [] = pure []
    go nextIndex (definition@FixtureDefinition {name, includes, steps} : rest) = do
      (capturedSteps, afterIndex) <- captureSteps nextIndex definition steps
      let identity = hashBuilder (fixtureEncoding name includes capturedSteps)
          captured = CapturedFixture {name, includes, steps = capturedSteps, identity}
      (captured :) <$> go afterIndex rest

    captureSteps :: Int -> FixtureDefinition -> [FixtureStep] -> ExceptT BundleError IO ([CapturedStep], Int)
    captureSteps nextIndex _ [] = pure ([], nextIndex)
    captureSteps nextIndex FixtureDefinition {name} (step : rest) = do
      let sourceDirectory = root </> Text.unpack (fixtureNameText name)
          relativePath = "step-" ++ show nextIndex
          output = staging </> relativePath
          input =
            sourceDirectory </> case step of
              SqlFile path -> path
              CopyCsv CopySpec {file} -> file
      source <- lift (canonicalizePath input)
      exists <- lift (doesFileExist source)
      unless (exists && within root source) (throwE (UnsafePath input))
      (byteCount, contentDigest) <- copyAndHash config source output (case step of SqlFile {} -> True; CopyCsv {} -> False)
      capturedStep <- case step of
        SqlFile {} -> do
          sql <- lift (ByteString.readFile output)
          either (throwE . InvalidSql input) (const (pure ())) (checkSqlPolicy sql)
          pure CapturedSql {relativePath, contentDigest, byteLength = byteCount}
        CopyCsv spec -> pure CapturedCopy {copySpec = spec, relativePath, contentDigest, byteLength = byteCount}
      (remaining, afterIndex) <- captureSteps (nextIndex + 1) FixtureDefinition {name, includes = [], steps = []} rest
      pure (capturedStep : remaining, afterIndex)

copyAndHash :: BundleConfig -> FilePath -> FilePath -> Bool -> ExceptT BundleError IO (Word64, Text)
copyAndHash config source output isSql = do
  sizeBefore <- lift (getFileSize source)
  modifiedBefore <- lift (getModificationTime source)
  result <- lift $ withBinaryFile source ReadMode $ \input ->
    withBinaryFile output WriteMode $ \destination -> loop input destination 0 SHA256.init
  (byteCount, hashContext) <- either throwE pure result
  sizeAfter <- lift (getFileSize source)
  modifiedAfter <- lift (getModificationTime source)
  when (sizeBefore /= sizeAfter || modifiedBefore /= modifiedAfter) (throwE (SourceChanged source))
  pure (byteCount, hex (SHA256.finalize hashContext))
  where
    limit = fromIntegral (positiveValue (sqlSizeLimit config)) :: Word64
    chunk = min 1048576 (positiveValue (chunkSize config))
    loop :: Handle -> Handle -> Word64 -> SHA256.Ctx -> IO (Either BundleError (Word64, SHA256.Ctx))
    loop input destination byteCount context = do
      bytes <- ByteString.hGet input chunk
      if ByteString.null bytes
        then pure (Right (byteCount, context))
        else do
          let newLength = byteCount + fromIntegral (ByteString.length bytes)
          if isSql && newLength > limit
            then pure (Left (SqlStepTooLarge source))
            else do
              ByteString.hPut destination bytes
              loop input destination newLength (SHA256.update context bytes)

publish :: FilePath -> FilePath -> Text -> ByteString -> [CapturedFixture] -> IO FilePath
publish bundleRoot staging digest manifest captured = do
  let preferred = bundleRoot </> ("v1-" ++ Text.unpack digest)
      unique = preferred ++ "-" ++ takeFileName staging
  exists <- doesDirectoryExist preferred
  if exists
    then do
      valid <- verifyBundle preferred manifest captured
      if valid then pure preferred else renameDirectory staging unique >> pure unique
    else do
      result <- try @IOException (renameDirectory staging preferred)
      case result of
        Right () -> pure preferred
        Left _ -> do
          valid <- verifyBundle preferred manifest captured
          if valid then pure preferred else renameDirectory staging unique >> pure unique

verifyBundle :: FilePath -> ByteString -> [CapturedFixture] -> IO Bool
verifyBundle directory manifest captured = do
  result <- try @IOException $ do
    directoryIsLink <- pathIsSymbolicLink directory
    if directoryIsLink
      then pure False
      else do
        manifestIsLink <- pathIsSymbolicLink (directory </> "manifest.bin")
        if manifestIsLink
          then pure False
          else do
            stored <- ByteString.readFile (directory </> "manifest.bin")
            if stored /= manifest
              then pure False
              else and <$> traverse verifyStep [step | CapturedFixture {steps = capturedSteps} <- captured, step <- capturedSteps]
  pure (either (const False) id result)
  where
    verifyStep step = do
      let path = directory </> relativePath step
      exists <- doesFileExist path
      if not exists
        then pure False
        else do
          isLink <- pathIsSymbolicLink path
          if isLink
            then pure False
            else do
              size <- getFileSize path
              digest <- hashFile path
              pure (size == fromIntegral (byteLength step) && digest == contentDigest step)

hashFile :: FilePath -> IO Text
hashFile path = withBinaryFile path ReadMode (go SHA256.init)
  where
    go context handle = do
      bytes <- ByteString.hGet handle 65536
      if ByteString.null bytes
        then pure (hex (SHA256.finalize context))
        else go (SHA256.update context bytes) handle

within :: FilePath -> FilePath -> Bool
within root candidate =
  let relative = makeRelative root candidate
   in not (isAbsolute relative) && relative /= ".." && not ("../" `isPrefixOf` relative)

planEncoding :: [CapturedFixture] -> Builder
planEncoding fixtures = field "hinagata-plan-v1" <> count fixtures <> foldMap (field . identity) fixtures

manifestEncoding :: Text -> [CapturedFixture] -> Builder
manifestEncoding digest fixtures =
  field "hinagata-bundle-v1" <> field digest <> count fixtures <> foldMap encodeFixture fixtures
  where
    encodeFixture CapturedFixture {name, includes, steps, identity} =
      field (fixtureNameText name)
        <> field identity
        <> count includes
        <> foldMap (field . fixtureNameText) includes
        <> count steps
        <> foldMap encodeStepManifest steps

fixtureEncoding :: FixtureName -> [FixtureName] -> [CapturedStep] -> Builder
fixtureEncoding name includes steps =
  field "hinagata-fixture-v1"
    <> field (fixtureNameText name)
    <> count includes
    <> foldMap (field . fixtureNameText) includes
    <> count steps
    <> foldMap encodeStepContent steps

encodeStepManifest :: CapturedStep -> Builder
encodeStepManifest step = field (Text.pack (relativePath step)) <> encodeStepContent step

encodeStepContent :: CapturedStep -> Builder
encodeStepContent CapturedSql {contentDigest, byteLength} =
  word8 1 <> field contentDigest <> word64BE byteLength
encodeStepContent CapturedCopy {copySpec = CopySpec {schema, table, columns, file, header}, contentDigest, byteLength} =
  word8 2
    <> field (Text.pack file)
    <> field (sqlIdentifierText schema)
    <> field (sqlIdentifierText table)
    <> count columns
    <> foldMap (field . sqlIdentifierText) columns
    <> word8 (if header then 1 else 0)
    <> field contentDigest
    <> word64BE byteLength

field :: Text -> Builder
field value =
  let bytes = Encoding.encodeUtf8 value
   in word64BE (fromIntegral (ByteString.length bytes)) <> byteString bytes

count :: [a] -> Builder
count = word64BE . fromIntegral . length

strictBuilder :: Builder -> ByteString
strictBuilder = Lazy.toStrict . toLazyByteString

hashBuilder :: Builder -> Text
hashBuilder = hex . SHA256.hash . strictBuilder

hex :: ByteString -> Text
hex = Text.pack . concatMap twoDigits . ByteString.unpack
  where
    twoDigits byte = case showHex byte "" of
      [digit] -> ['0', digit]
      digits -> digits
