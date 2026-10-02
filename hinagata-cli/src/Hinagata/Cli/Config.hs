module Hinagata.Cli.Config
  ( ConfigFailure (..),
    resolveConfig,
  )
where

import Data.Text qualified as Text
import Hinagata.Cli.Options (CliOptions (..))
import Hinagata.Config (HinagataConfig, hinagataConfig, hinagataEnvironmentBindings)
import Settei qualified
import Settei.Env qualified as Env
import Settei.Optparse qualified as SetteiOptions
import Settei.Yaml qualified as Yaml
import System.Environment (getEnvironment)

data ConfigFailure
  = SourceFailure !Text.Text
  | ResolutionFailure !Text.Text !Text.Text
  deriving stock (Eq, Show)

-- | Files are loaded in command-line order, then environment bindings and
-- repeated overrides. Settei's declaration supplies built-in defaults.
resolveConfig :: CliOptions -> IO (Either ConfigFailure (HinagataConfig, Settei.ResolveResult HinagataConfig))
resolveConfig CliOptions {configPaths, overrides, diagnosticMode} = do
  case hinagataEnvironmentBindings of
    Left problems -> pure (Left (SourceFailure (Env.renderEnvErrorsText problems)))
    Right bindings -> do
      fileResults <- traverse (\(index, path) -> Yaml.readYamlSource (Yaml.yamlSourceOptions ("config #" <> Text.pack (show index))) path) (zip [1 :: Int ..] configPaths)
      case traverse (either (Left . SourceFailure . Yaml.renderYamlErrorsText) Right) fileResults of
        Left failure -> pure (Left failure)
        Right files -> do
          environment <- getEnvironment
          let snapshot = Env.envSnapshot [(Text.pack key, Text.pack value) | (key, value) <- environment]
              sources = files <> [Env.environmentSource bindings snapshot] <> SetteiOptions.cliSources "arguments" overrides
              result@Settei.ResolveResult {answer, report} = Settei.resolve Settei.defaultResolveOptions sources hinagataConfig
          pure $ case answer of
            Left problems ->
              let detail = Settei.renderErrorsText problems
                  explanation = case diagnosticMode of
                    SetteiOptions.ExplainText -> Settei.renderResolutionText report
                    SetteiOptions.ExplainJson -> Settei.renderResolutionJson report <> "\n"
                    _ -> ""
               in Left (ResolutionFailure detail explanation)
            Right configuration -> Right (configuration, result)
