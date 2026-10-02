module Hinagata.Cli.Options
  ( CliOptions (..),
    Command (..),
    Shell (..),
    parserInfo,
  )
where

import Control.Applicative (optional, some)
import Data.Text qualified as Text
import Options.Applicative (Parser, ParserInfo)
import Options.Applicative qualified as Options
import Settei.Optparse qualified as SetteiOptions

data Shell = Bash | Zsh | Fish
  deriving stock (Eq, Show)

data Command
  = FixturePlan ![Text.Text] !Bool
  | FixtureLoad ![Text.Text] !Text.Text !Bool
  | Completions !Shell
  deriving stock (Eq, Show)

data CliOptions = CliOptions
  { configPaths :: ![FilePath],
    overrides :: ![SetteiOptions.CliOverride],
    diagnosticMode :: !SetteiOptions.DiagnosticMode,
    command :: !(Maybe Command)
  }

parserInfo :: String -> ParserInfo CliOptions
parserInfo version =
  Options.info
    (cliOptionsParser Options.<**> Options.helper Options.<**> Options.infoOption version (Options.long "version" <> Options.help "Show package version and build revision"))
    (Options.fullDesc <> Options.progDesc "Plan fixtures and manage isolated PostgreSQL test databases" <> Options.failureCode 2)

cliOptionsParser :: Parser CliOptions
cliOptionsParser =
  CliOptions
    <$> Options.parserOptionGroup "Configuration" SetteiOptions.configPathOptions
    <*> Options.parserOptionGroup "Configuration" SetteiOptions.overrideOptions
    <*> Options.parserOptionGroup "Diagnostics" SetteiOptions.diagnosticModeOptions
    <*> optional commandParser

commandParser :: Parser Command
commandParser =
  Options.hsubparser
    ( Options.command "fixture" (Options.info fixtureParser (Options.progDesc "Plan or load fixture sources"))
        <> Options.command "completions" (Options.info completionParser (Options.progDesc "Print a shell completion script"))
    )

fixtureParser :: Parser Command
fixtureParser =
  Options.hsubparser
    ( Options.command "plan" (Options.info planParser (Options.progDesc "Compile and inspect a fixture plan without PostgreSQL"))
        <> Options.command "load" (Options.info loadParser (Options.progDesc "Transactionally load fixtures into an existing test database"))
    )

planParser :: Parser Command
planParser =
  FixturePlan
    <$> (fmap Text.pack <$> some (Options.strArgument (Options.metavar "NAME...")))
    <*> Options.switch (Options.long "json" <> Options.help "Print versioned JSON")

loadParser :: Parser Command
loadParser =
  FixtureLoad
    <$> (fmap Text.pack <$> some (Options.strArgument (Options.metavar "NAME...")))
    <*> (Text.pack <$> Options.strOption (Options.long "target-database" <> Options.metavar "DATABASE" <> Options.help "Existing caller-owned test database to write"))
    <*> Options.switch (Options.long "json" <> Options.help "Print versioned JSON")

completionParser :: Parser Command
completionParser = Completions <$> Options.argument shellReader (Options.metavar "bash|zsh|fish")

shellReader :: Options.ReadM Shell
shellReader = Options.eitherReader $ \case
  "bash" -> Right Bash
  "zsh" -> Right Zsh
  "fish" -> Right Fish
  _ -> Left "expected bash, zsh, or fish"
