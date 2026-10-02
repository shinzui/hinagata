module Hinagata.Cli.Options
  ( CliOptions (..),
    Command (..),
    Shell (..),
    parserInfo,
  )
where

import Control.Applicative (many, optional, some)
import Data.Text qualified as Text
import Options.Applicative (Parser, ParserInfo)
import Options.Applicative qualified as Options
import Settei.Optparse qualified as SetteiOptions

data Shell = Bash | Zsh | Fish
  deriving stock (Eq, Show)

data Command
  = FixturePlan ![Text.Text] !Bool
  | FixtureLoad ![Text.Text] !Text.Text !Bool
  | FixtureValidate ![Text.Text] !Bool !Bool
  | DbPrepare !Bool
  | DbAcquire ![Text.Text] !Bool
  | DbWith ![Text.Text] !Bool !Bool ![String]
  | DbRelease !Text.Text !Bool
  | Inspect !Text.Text !Bool
  | Clean !Bool !Bool ![Text.Text] !Bool
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
        <> Options.command "db" (Options.info dbParser (Options.progDesc "Manage isolated database leases"))
        <> Options.command "inspect" (Options.info inspectParser (Options.progDesc "Inspect a lease by ID"))
        <> Options.command "clean" (Options.info cleanParser (Options.progDesc "Preview or apply ownership-checked cleanup"))
        <> Options.command "completions" (Options.info completionParser (Options.progDesc "Print a shell completion script"))
    )

fixtureParser :: Parser Command
fixtureParser =
  Options.hsubparser
    ( Options.command "plan" (Options.info planParser (Options.progDesc "Compile and inspect a fixture plan without PostgreSQL"))
        <> Options.command "load" (Options.info loadParser (Options.progDesc "Transactionally load fixtures into an existing test database"))
        <> Options.command "validate" (Options.info validateParser (Options.progDesc "Test each scenario in a separate isolated clone"))
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

validateParser :: Parser Command
validateParser =
  FixtureValidate
    <$> many (Text.pack <$> Options.strArgument (Options.metavar "NAME..."))
    <*> Options.switch (Options.long "all" <> Options.help "Discover all fixture sources")
    <*> jsonSwitch

dbParser :: Parser Command
dbParser =
  Options.hsubparser
    ( Options.command "prepare" (Options.info (DbPrepare <$> jsonSwitch) (Options.progDesc "Build or reuse a sealed baseline"))
        <> Options.command "acquire" (Options.info acquireParser (Options.progDesc "Acquire a detached isolated database"))
        <> Options.command "with" (Options.info withParser (Options.progDesc "Run one command with an isolated database lease"))
        <> Options.command "release" (Options.info releaseParser (Options.progDesc "Release a detached or retained lease"))
    )

acquireParser :: Parser Command
acquireParser =
  DbAcquire
    <$> many (Text.pack <$> Options.strOption (Options.long "fixture" <> Options.metavar "NAME" <> Options.help "Scenario fixture (repeatable)"))
    <*> jsonSwitch

withParser :: Parser Command
withParser =
  DbWith
    <$> many (Text.pack <$> Options.strOption (Options.long "fixture" <> Options.metavar "NAME" <> Options.help "Scenario fixture (repeatable)"))
    <*> Options.switch (Options.long "preserve-on-failure" <> Options.help "Retain a failed command's database for inspection")
    <*> jsonSwitch
    <*> some (Options.strArgument (Options.metavar "-- PROGRAM ARGS..."))

jsonSwitch :: Parser Bool
jsonSwitch = Options.switch (Options.long "json" <> Options.help "Print versioned JSON")

releaseParser :: Parser Command
releaseParser =
  DbRelease
    <$> (Text.pack <$> Options.strArgument (Options.metavar "LEASE_ID"))
    <*> Options.switch (Options.long "json" <> Options.help "Print versioned JSON")

inspectParser :: Parser Command
inspectParser =
  Inspect
    <$> (Text.pack <$> Options.strArgument (Options.metavar "LEASE_ID"))
    <*> Options.switch (Options.long "json" <> Options.help "Print versioned JSON")

cleanParser :: Parser Command
cleanParser =
  Clean
    <$> Options.switch (Options.long "apply" <> Options.help "Revalidate and apply cleanup to selected allocations")
    <*> Options.switch (Options.long "include-retained" <> Options.help "Allow explicitly selected retained allocations")
    <*> many (Text.pack <$> Options.strOption (Options.long "id" <> Options.metavar "ALLOCATION_ID" <> Options.help "Allocation to revalidate and clean"))
    <*> Options.switch (Options.long "json" <> Options.help "Print versioned JSON")

completionParser :: Parser Command
completionParser = Completions <$> Options.argument shellReader (Options.metavar "bash|zsh|fish")

shellReader :: Options.ReadM Shell
shellReader = Options.eitherReader $ \case
  "bash" -> Right Bash
  "zsh" -> Right Zsh
  "fish" -> Right Fish
  _ -> Left "expected bash, zsh, or fish"
