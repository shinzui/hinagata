# Small library adapter

[`TastyAdapter.hs`](TastyAdapter.hs) is compiled in the PostgreSQL test component. Run it with `nix develop -c just test-postgres`. Its `withPreparedManager` function calls `ensureBaseline` once, then keeps one manager and sealed baseline in scope for repeated isolated lease callbacks. `databaseCase` and `runDatabaseCase` show how a test callback returns `Either String ()`: `PreserveFailures` keeps a failed case's clone for inspection, while a successful case releases it. The adapter never changes a callback's value to hide a cleanup error.

For two named databases in one callback, the integration test in `test/Main.hs` calls `withDatabases` with two `DatabaseRequest` values and confirms distinct endpoints. It then gives the second request a bad scenario and verifies that the first clone is unwound. These examples use public Hinagata API types and run on the disposable PostgreSQL cluster supplied by the test script.
