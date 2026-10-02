module Hinagata.Cli.Output
  ( CliError (..),
    bundleError,
    loadError,
    cleanupError,
    emitError,
    emitLoad,
    emitPlan,
    emitCandidate,
    emitCleanupPlan,
    emitCleanupResults,
    emitPreparation,
    emitAcquisition,
    emitWith,
    withExitCode,
    ValidationResult (..),
    emitValidation,
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Json
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Hinagata.Cli.Process (ChildFailure (..), ChildReport (..))
import Hinagata.Connection (connectionDatabase, connectionHost, connectionPort, connectionUser, hostText)
import Hinagata.Fixture.Bundle
import Hinagata.Fixture.Types (fixtureNameText)
import Hinagata.Postgres.Baseline (FingerprintComparison (..), PreparationKind (..), PreparationReport (..), fingerprintComponents)
import Hinagata.Postgres.Cleanup (CleanupCandidate (..), CleanupDisposition (..), CleanupError (..), CleanupResult (..))
import Hinagata.Postgres.Error (LoadError (..))
import Hinagata.Postgres.Lease (LeaseError (..), LeaseInfo (..), LeaseOutcome (..), LeaseTimings (..))
import Hinagata.Postgres.Load (LoadReport (..))
import Hinagata.Types (DatabaseName, databaseNameText, portNumber)
import System.Exit (ExitCode (..))
import System.IO qualified as IO

data CliError = CliError
  { phase :: !Text.Text,
    code :: !Text.Text,
    message :: !Text.Text,
    fixture :: !(Maybe Text.Text),
    stepIndex :: !(Maybe Int),
    sqlState :: !(Maybe Text.Text),
    target :: !(Maybe Text.Text),
    exitCode :: !Int
  }
  deriving stock (Eq, Show)

data ValidationResult = ValidationResult
  { scenario :: !Text.Text,
    result :: !(Either CliError LeaseTimings)
  }

bundleError :: BundleError -> CliError
bundleError problem = case problem of
  BundleIo reason -> failure "bundle_io" reason Nothing
  MissingFixture name -> failure "fixture_missing" "fixture does not exist" (Just (fixtureNameText name))
  UnsafePath path -> failure "fixture_unsafe_path" (Text.pack path) Nothing
  InvalidFixtureManifest name _ -> failure "fixture_manifest_invalid" "fixture manifest is invalid" (Just (fixtureNameText name))
  InvalidFixtureGraph _ -> failure "fixture_graph_invalid" "fixture graph is invalid" Nothing
  SourceChanged path -> failure "fixture_source_changed" (Text.pack path) Nothing
  SqlStepTooLarge path -> failure "fixture_sql_too_large" (Text.pack path) Nothing
  InvalidSql path _ -> failure "fixture_sql_invalid" (Text.pack path) Nothing
  where
    failure code message fixture = CliError "fixture-plan" code message fixture Nothing Nothing Nothing 1

loadError :: LoadError -> CliError
loadError LoadError {phase, targetIdentity, fixture, stepIndex, cause, sqlState} =
  CliError (Text.pack (show phase)) "load_failed" cause (fixtureNameText <$> fixture) stepIndex sqlState targetIdentity 1

cleanupError :: CleanupError -> CliError
cleanupError CleanupError {cause, sqlState} = CliError "cleanup" "cleanup_failed" cause Nothing Nothing sqlState Nothing 1

emitCandidate :: Bool -> Maybe CleanupCandidate -> IO ()
emitCandidate jsonSelected found =
  if jsonSelected
    then emitValue (Json.object ["formatVersion" .= (1 :: Int), "ok" .= True, "kind" .= ("inspect" :: Text.Text), "candidate" .= fmap candidateValue found])
    else case found of
      Nothing -> TextIO.putStrLn "lease not found"
      Just CleanupCandidate {allocationId, database, state, disposition} ->
        TextIO.putStrLn (allocationId <> " " <> databaseNameText database <> " " <> state <> " " <> dispositionText disposition)

emitCleanupPlan :: Bool -> [CleanupCandidate] -> IO ()
emitCleanupPlan jsonSelected candidates =
  if jsonSelected
    then emitValue (Json.object ["formatVersion" .= (1 :: Int), "ok" .= True, "kind" .= ("cleanup-preview" :: Text.Text), "candidates" .= map candidateValue candidates])
    else mapM_ (emitCandidate False . Just) candidates

emitCleanupResults :: Bool -> [CleanupResult] -> IO ()
emitCleanupResults jsonSelected results =
  if jsonSelected
    then emitValue (Json.object ["formatVersion" .= (1 :: Int), "ok" .= all successful results, "kind" .= ("cleanup-apply" :: Text.Text), "results" .= map cleanupResultValue results])
    else mapM_ (TextIO.putStrLn . resultText) results
  where
    successful (Released _) = True
    successful (AlreadyReleased _) = True
    successful (Preserved _) = True
    successful _ = False

candidateValue :: CleanupCandidate -> Json.Value
candidateValue CleanupCandidate {allocationId, leaseId, database, state, disposition} =
  Json.object ["allocationId" .= allocationId, "leaseId" .= leaseId, "database" .= databaseNameText database, "state" .= state, "disposition" .= dispositionText disposition]

dispositionText :: CleanupDisposition -> Text.Text
dispositionText = Text.pack . show

cleanupResultValue :: CleanupResult -> Json.Value
cleanupResultValue result = Json.object ["id" .= resultId result, "code" .= resultCode result, "outcome" .= resultText result, "reason" .= resultReason result]

resultCode :: CleanupResult -> Text.Text
resultCode = \case
  Released _ -> "released"
  AlreadyReleased _ -> "already_released"
  Preserved _ -> "preserved"
  Skipped _ _ -> "skipped"
  Refused _ _ -> "refused"

resultReason :: CleanupResult -> Maybe Text.Text
resultReason = \case
  Refused _ reason -> Just reason
  _ -> Nothing

resultId :: CleanupResult -> Text.Text
resultId = \case
  Released identifier -> identifier
  AlreadyReleased identifier -> identifier
  Preserved identifier -> identifier
  Skipped identifier _ -> identifier
  Refused identifier _ -> identifier

resultText :: CleanupResult -> Text.Text
resultText = \case
  Released identifier -> "released " <> identifier
  AlreadyReleased identifier -> "already released " <> identifier
  Preserved identifier -> "preserved " <> identifier
  Skipped identifier disposition -> "skipped " <> identifier <> " (" <> dispositionText disposition <> ")"
  Refused identifier reason -> "refused " <> identifier <> ": " <> reason

emitValue :: Json.Value -> IO ()
emitValue value = Lazy.putStr (Json.encode value <> "\n")

emitValidation :: Bool -> [ValidationResult] -> IO ()
emitValidation jsonSelected results =
  if jsonSelected
    then emitValue (Json.object ["formatVersion" .= (1 :: Int), "ok" .= all passed results, "kind" .= ("fixture-validate" :: Text.Text), "results" .= map resultValue results])
    else mapM_ (\ValidationResult {scenario, result} -> TextIO.putStrLn (scenario <> if either (const False) (const True) result then " passed" else " failed")) results
  where
    passed ValidationResult {result} = either (const False) (const True) result
    resultValue ValidationResult {scenario, result} =
      Json.object ["scenario" .= scenario, "ok" .= either (const False) (const True) result, "error" .= either (Just . validationErrorValue) (const Nothing) result, "timingsMs" .= either (const Nothing) (Just . timingValue) result]
    timingValue LeaseTimings {queueWaitMs, catalogMs, generationLockMs, cloneMs, scenarioLoadMs, completionMs} =
      Json.object ["queueWait" .= queueWaitMs, "catalog" .= catalogMs, "generationLock" .= generationLockMs, "clone" .= cloneMs, "scenarioLoad" .= scenarioLoadMs, "completion" .= completionMs]

validationErrorValue :: CliError -> Json.Value
validationErrorValue CliError {phase, code, message, fixture, stepIndex, sqlState, target} =
  Json.object ["phase" .= phase, "code" .= code, "message" .= message, "fixture" .= fixture, "stepIndex" .= stepIndex, "sqlState" .= sqlState, "target" .= target]

emitPreparation :: Bool -> PreparationReport -> IO ()
emitPreparation jsonSelected PreparationReport {kind, fingerprint, elapsedMs, comparison} =
  if jsonSelected
    then emitValue (Json.object ["formatVersion" .= (1 :: Int), "ok" .= True, "kind" .= ("baseline-prepare" :: Text.Text), "result" .= Text.pack (show kind), "reason" .= preparationReason kind, "fingerprint" .= fingerprint, "fingerprintCategories" .= map (Text.pack . show) fingerprintComponents, "elapsedMs" .= elapsedMs, "comparison" .= fmap comparisonValue comparison])
    else TextIO.putStrLn (Text.pack (show kind) <> " baseline " <> fingerprint <> " in " <> Text.pack (show elapsedMs) <> " ms")

preparationReason :: PreparationKind -> Text.Text
preparationReason Built = "no-matching-ready-generation"
preparationReason Reused = "matching-sealed-generation"

comparisonValue :: FingerprintComparison -> Json.Value
comparisonValue FingerprintComparison {previousFingerprint, changedComponents} =
  Json.object ["previousFingerprint" .= previousFingerprint, "changedComponents" .= map (Text.pack . show) changedComponents]

emitAcquisition :: Bool -> LeaseInfo -> LeaseTimings -> IO ()
emitAcquisition jsonSelected LeaseInfo {leaseId, runId, applicationTarget} LeaseTimings {queueWaitMs, catalogMs, generationLockMs, cloneMs, scenarioLoadMs, completionMs} =
  if jsonSelected
    then emitValue (Json.object ["formatVersion" .= (1 :: Int), "ok" .= True, "kind" .= ("db-acquire" :: Text.Text), "leaseId" .= leaseId, "runId" .= runId, "database" .= databaseNameText (connectionDatabase applicationTarget), "host" .= hostText (connectionHost applicationTarget), "port" .= portNumber (connectionPort applicationTarget), "user" .= connectionUser applicationTarget, "timingsMs" .= Json.object ["queueWait" .= queueWaitMs, "catalog" .= catalogMs, "generationLock" .= generationLockMs, "clone" .= cloneMs, "scenarioLoad" .= scenarioLoadMs, "completion" .= completionMs]])
    else TextIO.putStrLn ("acquired " <> leaseId <> " " <> databaseNameText (connectionDatabase applicationTarget))

withExitCode :: LeaseOutcome (Either ChildFailure ChildReport) -> Int
withExitCode LeaseOutcome {callbackValue, cleanupDiagnostic} =
  let childStatus = case callbackValue of
        Left _ -> 1
        Right ChildReport {cancelledBy = Just signal} -> 128 + signal
        Right ChildReport {timedOut = True} -> 1
        Right ChildReport {childExit = Just ExitSuccess, cleanupFailure = Nothing} -> 0
        Right ChildReport {childExit = Just (ExitFailure status)} -> if status < 0 then 128 - status else status
        Right _ -> 1
   in if childStatus == 0 && cleanupDiagnostic /= Nothing then 1 else childStatus

emitWith :: Bool -> LeaseOutcome (Either ChildFailure ChildReport) -> IO ()
emitWith jsonSelected outcome@LeaseOutcome {callbackValue, leaseInfo = LeaseInfo {leaseId, runId}, leaseDisposition, cleanupDiagnostic, timings} = do
  let status = withExitCode outcome
      childValue = case callbackValue of
        Left ChildSpawnFailed -> Json.object ["outcome" .= ("spawn-failed" :: Text.Text)]
        Left ChildIdentityUnavailable -> Json.object ["outcome" .= ("identity-unavailable" :: Text.Text)]
        Right ChildReport {childExit, timedOut, cancelledBy, cleanupFailure} ->
          Json.object ["outcome" .= (if timedOut then "timed-out" else if cancelledBy /= Nothing then "cancelled" else "exited" :: Text.Text), "exitCode" .= fmap exitNumber childExit, "signal" .= cancelledBy, "processCleanup" .= cleanupFailure]
      LeaseTimings {queueWaitMs, catalogMs, generationLockMs, cloneMs, scenarioLoadMs, completionMs} = timings
      cleanupValue = fmap (\LeaseError {cause, sqlState, cleanupFailure} -> Json.object ["message" .= cause, "sqlState" .= sqlState, "detail" .= cleanupFailure]) cleanupDiagnostic
  if jsonSelected
    then emitValue (Json.object ["formatVersion" .= (1 :: Int), "ok" .= (status == 0), "kind" .= ("db-with" :: Text.Text), "leaseId" .= leaseId, "runId" .= runId, "disposition" .= Text.pack (show leaseDisposition), "status" .= status, "child" .= childValue, "databaseCleanup" .= cleanupValue, "timingsMs" .= Json.object ["queueWait" .= queueWaitMs, "catalog" .= catalogMs, "generationLock" .= generationLockMs, "clone" .= cloneMs, "scenarioLoad" .= scenarioLoadMs, "completion" .= completionMs]])
    else TextIO.putStrLn ("lease " <> leaseId <> " " <> Text.pack (show leaseDisposition) <> "; command status " <> Text.pack (show status))
  if status /= 0 then TextIO.hPutStrLn IO.stderr ("db with: command status " <> Text.pack (show status) <> "; lease " <> leaseId <> " " <> Text.pack (show leaseDisposition)) else pure ()
  where
    exitNumber ExitSuccess = 0 :: Int
    exitNumber (ExitFailure status) = if status < 0 then 128 - status else status

emitError :: Bool -> CliError -> IO ()
emitError jsonSelected CliError {phase, code, message, fixture, stepIndex, sqlState, target} = do
  TextIO.hPutStrLn IO.stderr (phase <> ": " <> code <> ": " <> message)
  if jsonSelected
    then
      Lazy.putStr
        ( Json.encode
            ( Json.object
                [ "formatVersion" .= (1 :: Int),
                  "ok" .= False,
                  "error"
                    .= Json.object
                      [ "phase" .= phase,
                        "code" .= code,
                        "message" .= message,
                        "fixture" .= fixture,
                        "stepIndex" .= stepIndex,
                        "sqlState" .= sqlState,
                        "target" .= target
                      ]
                ]
            )
            <> "\n"
        )
    else pure ()

emitLoad :: Bool -> DatabaseName -> LoadReport -> IO ()
emitLoad jsonSelected database LoadReport {fixtureCount, stepCount, bytesSent, verifyMs, setupMs, sqlMs, copyMs, commitMs, elapsedMs} =
  if jsonSelected
    then
      Lazy.putStr
        ( Json.encode
            ( Json.object
                [ "formatVersion" .= (1 :: Int),
                  "ok" .= True,
                  "kind" .= ("fixture-load" :: Text.Text),
                  "database" .= databaseNameText database,
                  "fixtureCount" .= fixtureCount,
                  "stepCount" .= stepCount,
                  "bytesSent" .= bytesSent,
                  "timingsMs" .= Json.object ["verify" .= verifyMs, "setup" .= setupMs, "sql" .= sqlMs, "copy" .= copyMs, "commit" .= commitMs, "elapsed" .= elapsedMs]
                ]
            )
            <> "\n"
        )
    else TextIO.putStrLn ("loaded " <> Text.pack (show fixtureCount) <> " fixtures into " <> databaseNameText database)

emitPlan :: Bool -> FixturePlan -> IO ()
emitPlan jsonSelected plan =
  if jsonSelected
    then Lazy.putStr (Json.encode planValue <> "\n")
    else do
      TextIO.putStrLn ("plan " <> planDigest plan)
      mapM_ (TextIO.putStrLn . ("fixture " <>) . fixtureNameText . name) (planFixtures plan)
  where
    planValue =
      Json.object
        [ "formatVersion" .= (1 :: Int),
          "ok" .= True,
          "kind" .= ("fixture-plan" :: Text.Text),
          "digest" .= planDigest plan,
          "fixtures" .= map fixtureValue (planFixtures plan)
        ]

fixtureValue :: CapturedFixture -> Json.Value
fixtureValue CapturedFixture {name, includes, steps, identity} =
  Json.object
    [ "name" .= fixtureNameText name,
      "includes" .= map fixtureNameText includes,
      "identity" .= identity,
      "steps" .= map stepValue steps
    ]

stepValue :: CapturedStep -> Json.Value
stepValue CapturedSql {relativePath, contentDigest, byteLength} =
  Json.object ["type" .= ("sql" :: Text.Text), "path" .= relativePath, "digest" .= contentDigest, "bytes" .= byteLength]
stepValue CapturedCopy {relativePath, contentDigest, byteLength} =
  Json.object ["type" .= ("copy" :: Text.Text), "path" .= relativePath, "digest" .= contentDigest, "bytes" .= byteLength]
