-- | A small Tasty adapter kept in the test component so the library has no
-- dependency on a particular test framework. Build with
-- @nix develop -c cabal build hinagata-postgres:hinagata-postgres-test@.
module TastyAdapter (databaseCase, runDatabaseCase) where

import Data.Either (isLeft)
import Hinagata.Fixture.Bundle (FixturePlan)
import Hinagata.Postgres.Baseline (BaselineRef)
import Hinagata.Postgres.Lease (LeaseDisposition (..), LeaseInfo, LeaseOutcome (..), RetentionPolicy (..))
import Hinagata.Postgres.Manager (Manager, withManagedDatabaseClassified)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertFailure, testCase)

-- | Construct a Tasty case around a prepared suite-scoped manager and frozen
-- fixture plans. A failed assertion returned as 'Left' retains its clone for
-- inspection; a successful case releases it when the callback closes its
-- application connections.
databaseCase :: String -> Manager -> BaselineRef -> FixturePlan -> (LeaseInfo -> IO (Either String ())) -> TestTree
databaseCase name manager baseline scenario check = testCase name (runDatabaseCase manager baseline scenario check)

runDatabaseCase :: Manager -> BaselineRef -> FixturePlan -> (LeaseInfo -> IO (Either String ())) -> IO ()
runDatabaseCase manager baseline scenario check = do
  result <- withManagedDatabaseClassified manager baseline scenario PreserveFailures isLeft check
  case result of
    Left problem -> assertFailure ("database acquisition failed: " ++ show problem)
    Right LeaseOutcome {callbackValue = Left message, leaseInfo} -> assertFailure (message ++ "; retained lease: " ++ show leaseInfo)
    Right LeaseOutcome {callbackValue = Right (), leaseDisposition = LeaseReleased, cleanupDiagnostic = Nothing} -> pure ()
    Right outcome -> assertFailure ("database cleanup failed: " ++ show outcome)
