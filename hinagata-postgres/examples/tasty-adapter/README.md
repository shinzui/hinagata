# Tasty adapter for managed database cases

`TastyAdapter.databaseCase` wraps a prepared `Manager`, `BaselineRef`, and
`FixturePlan` in a `TestTree`. Keep `withManager` around the entire test run,
prepare the baseline and scenario once, and pass a callback that opens its
application connection from `LeaseInfo.applicationTarget` and closes it before
returning. The integration suite compiles this module and executes its
`runDatabaseCase` path on a disposable PostgreSQL cluster.

```haskell
import Test.Tasty (defaultMain, testGroup)
import TastyAdapter (databaseCase)

-- Inside a suite setup scope that has prepared manager, baseline, and scenario:
defaultMain $
  testGroup "service database" [
    databaseCase "creates an account" manager baseline scenario $ \lease -> do
      -- Run the service assertion using applicationTarget lease.
      -- Return Left with a useful message for a failed assertion.
      pure (Right ())
  ]
```

A returned `Left` is classified as a test failure and preserves its clone for
inspection. A successful `Right ()` releases it. Synchronous exceptions raised
inside the callback also preserve it; asynchronous cancellation attempts
release. The adapter reports the retained lease ID in the test failure. Use
`releaseLease` or explicit cleanup when that retained database is no longer
needed. The production library does not depend on Tasty.

Build the example module with
`nix develop -c cabal build hinagata-postgres:hinagata-postgres-test`, then run
it against a disposable socket cluster with `nix develop -c just test-postgres`.
