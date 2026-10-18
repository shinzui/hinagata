module Hinagata.Cli.Config
  ( ConfigFailure (..),
    CliSettings (..),
    HookSettings (..),
    cliConfiguration,
    resolveConfig,
    validateHook,
  )
where

import Control.Monad (void)
import Data.Text qualified as Text
import Hinagata.Cli.Options (CliOptions (..))
import Hinagata.Cli.Process (parseOverlay)
import Hinagata.Config (HinagataConfig, hinagataConfig, hinagataEnvironmentBindings)
import Settei qualified
import Settei.Env qualified as Env
import Settei.Optparse qualified as SetteiOptions
import Settei.Yaml qualified as Yaml
import System.Environment (getEnvironment)
import System.FilePath (isAbsolute)
import Text.Read (readMaybe)

data ConfigFailure
  = SourceFailure !Text.Text
  | ResolutionFailure !Text.Text !Text.Text
  deriving stock (Eq, Show)

data HookSettings = HookSettings
  { executable :: !(Maybe Text.Text),
    arguments :: ![Text.Text],
    workingDirectory :: !(Maybe Text.Text),
    environment :: ![Text.Text],
    revision :: !(Maybe Text.Text),
    deadlineMs :: !Int
  }
  deriving stock (Eq)

data CliSettings = CliSettings
  { baseFixtures :: ![Text.Text],
    migration :: !HookSettings,
    verification :: !HookSettings,
    clonePreparation :: !HookSettings
  }
  deriving stock (Eq)

cliConfiguration :: Settei.Config (HinagataConfig, CliSettings)
cliConfiguration = (,) <$> hinagataConfig <*> settings

settings :: Settei.Config CliSettings
settings =
  CliSettings
    <$> listSetting "baseline.fixtures" "Base fixtures loaded into every sealed template"
    <*> hookSettings "migration"
    <*> hookSettings "verification"
    <*> hookSettings "clone.preparation"

hookSettings :: Text.Text -> Settei.Config HookSettings
hookSettings prefix =
  HookSettings
    <$> optionalText (prefix <> ".executable") ("Executable to run against the " <> if prefix == "clone.preparation" then "fresh clone" else "baseline database")
    <*> secretListSetting (prefix <> ".argv") "Argument vector passed without shell evaluation"
    <*> optionalText (prefix <> ".cwd") "Working directory for the hook"
    <*> secretListSetting (prefix <> ".environment") "Explicit NAME=VALUE child environment overlay"
    <*> (if prefix == "clone.preparation" then pure Nothing else optionalText (prefix <> ".revision") "Declared revision identifying the hook's effects")
    <*> Settei.withDefault
      (Settei.publicShowSetting (settingKey (prefix <> ".deadline_ms")) "Hook deadline in milliseconds" deadlineDecoder)
      (Settei.constantDefault (Settei.RuleName (prefix <> "-deadline")) "Bound hook execution" (300000 :: Int))

optionalText :: Text.Text -> Text.Text -> Settei.Config (Maybe Text.Text)
optionalText name description = Settei.optional (Settei.publicSetting (settingKey name) description Settei.textDecoder)

listSetting :: Text.Text -> Text.Text -> Settei.Config [Text.Text]
listSetting name description =
  Settei.withDefault
    (Settei.publicShowSetting (settingKey name) description (Settei.listDecoder Settei.textDecoder))
    (Settei.constantDefault (Settei.RuleName (name <> "-empty")) "No entries configured" [])

secretListSetting :: Text.Text -> Text.Text -> Settei.Config [Text.Text]
secretListSetting name description =
  Settei.withDefault
    (Settei.secretSetting (settingKey name) description (Settei.listDecoder Settei.textDecoder))
    (Settei.constantDefault (Settei.RuleName (name <> "-empty")) "No entries configured" [])

settingKey :: Text.Text -> Settei.Key
settingKey name = either (error . show) id (Settei.parseKey name)

deadlineDecoder :: Settei.Decoder Int
deadlineDecoder = Settei.parsedDecoder "a positive integer number of milliseconds" $ \value ->
  case readMaybe (Text.unpack value) of
    Just milliseconds | milliseconds > 0 -> Right milliseconds
    _ -> Left "deadline must be a positive integer"

-- | Files are loaded in command-line order, then environment bindings and
-- repeated overrides. Settei's declaration supplies built-in defaults.
resolveConfig :: CliOptions -> IO (Either ConfigFailure ((HinagataConfig, CliSettings), Settei.ResolveResult (HinagataConfig, CliSettings)))
resolveConfig CliOptions {configPaths, overrides, diagnosticMode} = do
  case hinagataEnvironmentBindings of
    Left problems -> pure (Left (SourceFailure (Env.renderEnvErrorsText problems)))
    Right bindings -> do
      let cliBindings =
            Env.bindings
              [ Env.binding (Env.EnvName ("HINAGATA_" <> Text.toUpper (Text.replace "." "_" name))) (settingKey name)
              | name <- ["migration.executable", "migration.cwd", "migration.revision", "migration.deadline_ms", "verification.executable", "verification.cwd", "verification.revision", "verification.deadline_ms", "clone.preparation.executable", "clone.preparation.cwd", "clone.preparation.deadline_ms"]
              ]
      case cliBindings of
        Left problems -> pure (Left (SourceFailure (Env.renderEnvErrorsText problems)))
        Right hookBindings -> resolveSources bindings hookBindings
  where
    resolveSources bindings hookBindings = do
      fileResults <- traverse (\(index, path) -> Yaml.readYamlSource (Yaml.yamlSourceOptions ("config #" <> Text.pack (show index))) path) (zip [1 :: Int ..] configPaths)
      case traverse (either (Left . SourceFailure . Yaml.renderYamlErrorsText) Right) fileResults of
        Left failure -> pure (Left failure)
        Right files -> do
          environment <- getEnvironment
          let snapshot = Env.envSnapshot [(Text.pack key, Text.pack value) | (key, value) <- environment]
              sources = files <> [Env.environmentSource bindings snapshot, Env.environmentSource hookBindings snapshot] <> SetteiOptions.cliSources "arguments" overrides
              result@Settei.ResolveResult {answer, report} = Settei.resolve Settei.defaultResolveOptions sources cliConfiguration
          pure $ case answer of
            Left problems ->
              let detail = Settei.renderErrorsText problems
                  explanation = case diagnosticMode of
                    SetteiOptions.ExplainText -> Settei.renderResolutionText report
                    SetteiOptions.ExplainJson -> Settei.renderResolutionJson report <> "\n"
                    _ -> ""
               in Left (ResolutionFailure detail explanation)
            Right configuration@(_, cli) -> case traverse (uncurry validateHook) [("migration", migration cli), ("verification", verification cli), ("clone.preparation", clonePreparation cli)] of
              Left problem -> Left (ResolutionFailure problem "")
              Right _ -> Right (configuration, result)

-- | Semantic checks also run for offline diagnostics, before any database work.
validateHook :: Text.Text -> HookSettings -> Either Text.Text ()
validateHook name HookSettings {executable, arguments, workingDirectory, environment, revision, deadlineMs}
  | deadlineMs <= 0 = invalid "hook deadline must be positive"
  | otherwise = case executable of
      Nothing
        | null arguments && workingDirectory == Nothing && null environment && revision == Nothing -> Right ()
        | otherwise -> invalid "hook settings require an executable"
      Just program
        | Text.null program || Text.any (== '\0') program -> invalid "hook executable is empty or contains NUL"
        | any (Text.any (== '\0')) arguments -> invalid "hook argv contains NUL"
        | maybe False (\path -> not (isAbsolute (Text.unpack path)) || Text.any (== '\0') path) workingDirectory -> invalid "hook cwd must be absolute and without NUL"
        | otherwise -> either invalid (const (Right ())) (void (parseOverlay environment))
  where
    invalid message = Left (name <> ": " <> message)
