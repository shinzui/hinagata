-- | Per-preparation capture of explicitly selected hook identity inputs.
module Hinagata.Cli.Revision
  ( HookRevision,
    captureHookRevision,
    effectiveRevision,
    verifyHookRevisions,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Hinagata.Cli.Config (HookSettings (..), revisionDeclarations)
import Hinagata.Cli.Output (CliError (..))
import Hinagata.Hook.Revision qualified as Revision
import System.FilePath (isAbsolute, (</>))

data HookRevision = HookRevision !Text !(Maybe Text) !(Maybe Revision.CapturedRevision)

effectiveRevision :: HookRevision -> Maybe Text
effectiveRevision (HookRevision _ revision _) = revision

captureHookRevision :: FilePath -> Text -> HookSettings -> IO (Either CliError HookRevision)
captureHookRevision invocation name settings = case revisionDeclarations settings of
  Left _ -> pure (Left (CliError "config-resolution" "config_resolution_invalid" (name <> ": invalid revision declaration") Nothing Nothing Nothing Nothing 4 Nothing Nothing))
  Right [] -> pure (Right (HookRevision name (revision settings) Nothing))
  Right inputs -> do
    let root = maybe invocation Text.unpack (workingDirectory settings)
        locate (Revision.FileInput label path) = Revision.FileInput label (if isAbsolute path then path else root </> path)
        locate input = input
    captured <- Revision.deriveHookRevision (map locate inputs)
    pure $ case captured of
      Left failure -> Left (revisionError name failure)
      Right evidence -> Right (HookRevision name (Just (Revision.hookRevision evidence)) (Just evidence))

verifyHookRevisions :: [HookRevision] -> IO (Either CliError ())
verifyHookRevisions [] = pure (Right ())
verifyHookRevisions (HookRevision _ _ Nothing : rest) = verifyHookRevisions rest
verifyHookRevisions (HookRevision name _ (Just evidence) : rest) = do
  checked <- Revision.verifyHookRevisionInputs evidence
  case checked of
    Left failure -> pure (Left (revisionError name failure))
    Right () -> verifyHookRevisions rest

revisionError :: Text -> Revision.RevisionError -> CliError
revisionError hook failure = CliError "hook-revision" code (hook <> ": " <> message) Nothing Nothing Nothing Nothing 1 Nothing Nothing
  where
    (code, message) = case failure of
      Revision.InputsChanged label -> ("hook_revision_inputs_changed", "selected input changed: " <> Revision.inputNameText label)
      Revision.InputUnreadable label -> ("hook_revision_input_unreadable", "selected input cannot be read: " <> Revision.inputNameText label)
      _ -> ("hook_revision_input_unreadable", "invalid selected inputs")
