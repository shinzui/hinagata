---
type: Guide
title: "Integrate a service"
description: "Run service migrations and tests with separate database roles and isolated clones."
docId: DOC-2
tags: ["integration", "access", "lifecycle"]
generated:
  by: process:codex
  at: 2026-10-02T16:49:46Z
---

# Integrate a service

This procedure assumes that you have a test PostgreSQL server and a service test command.
The server, global roles, and required extensions are prerequisites.
`CONFIG` is your Hinagata YAML file.
Replace all uppercase placeholders before execution.

## Prepare the service

1. Configure explicit administration, setup, and application connections.

   The administration role needs database creation and removal permissions.
   The setup role needs migration and fixture permissions.
   The application role needs only the access required by the service.
   See [Configuration reference](../user/configuration.md).

2. Supply a migration executable that uses the setup connection from PostgreSQL environment variables.
3. Supply a verification executable that checks the migrated schema.
4. Set truthful `migration.revision` and `verification.revision` values.
5. Make each executable close its database connections before exit.
6. Put shared data in `baseline.fixtures`.
7. Put test-specific changes in scenario fixtures.

   A scenario can include a base fixture when its captured identity is unchanged.
   Hinagata does not load the shared base fixture twice.
   Service migrations must grant application access to tables and sequences.

## Validate the setup

1. Validate the configuration.

   ```sh
   cabal run hinagata -- --config CONFIG --check-config
   ```

2. Compile a scenario.

   ```sh
   cabal run hinagata -- --config CONFIG fixture plan SCENARIO --json
   ```

3. Validate the scenario in a clone.

   ```sh
   cabal run hinagata -- --config CONFIG fixture validate SCENARIO --json
   ```

4. Prepare the baseline.

   ```sh
   cabal run hinagata -- --config CONFIG db prepare --json
   ```

   With stable revisions and unchanged inputs, later preparation reports `Reused`.
   The first successful build reports `Built`.

## Run the service test

1. Make your test wrapper read `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE`.
2. Make the wrapper stop the service and close its pools before exit.
3. Run the wrapper inside a lease.

   ```sh
   cabal run hinagata -- --config CONFIG db with --fixture SCENARIO -- PROGRAM ARGS...
   ```

   The wrapper receives application access to the clone.
   Hinagata releases the clone after the wrapper stops.
   Each independent service instance needs a separate lease.

4. Read [Inspect and release databases](manage-leases.md) if the command or cleanup fails.

For HTTP tests, `mori://shinzui/hurl-workbench` controls service startup, readiness, Hurl execution, and service shutdown.
Hinagata supplies the database lease for that procedure.
The [Keiro example](../../examples/keiro-service/README.md) includes a runnable service and migration executable.
Run it from the repository root with `nix develop -c just example-keiro`.

## Haskell consumers

`Hinagata.Postgres.Baseline.ensureBaseline` prepares a baseline from a `BaselineSpec`.
`Hinagata.Postgres.Lease.withDatabase` gives its callback a `LeaseInfo` with an application target.
The callback must close its pools before return.
`withDatabaseClassified` keeps the callback result and cleanup diagnostic separate.

`Hinagata.Postgres.Manager.withManager` supplies local admission limits.
`withManagedDatabase` uses those limits for one clone.
`withDatabases` acquires a named collection of clones.
The [Tasty example](../../hinagata-postgres/examples/tasty-adapter/README.md) shows suite integration.
Hinagata's public connection types do not require your service to use its database driver.
