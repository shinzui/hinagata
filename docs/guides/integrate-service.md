---
type: Guide
title: "Integrate a service"
description: "Run service migrations and tests with separate database roles and isolated clones."
docId: DOC-2
tags: ["integration", "access", "lifecycle"]
generated:
  by: process:codex
  at: 2026-10-18T20:45:25Z
---

# Integrate a service

This procedure assumes that you have a test PostgreSQL server and a service test command.
The server, global roles, and required extensions are prerequisites.
`CONFIG` is your Hinagata YAML file.
Replace all uppercase placeholders before execution.

Hinagata's libraries and CLI do not depend on Keiro.
Use your service's migration, verification, and optional preparation commands.
The Keiro commands below illustrate those hooks in a test-only example.

## Prepare the service

1. Configure explicit administration, setup, and application connections.

   The administration role needs database creation and removal permissions.
   The setup role needs migration and fixture permissions.
   The application role needs only the access required by the service.
   See [Configuration reference](../user/configuration.md).

2. Supply a migration executable that uses the setup connection from PostgreSQL environment variables.
3. Supply a verification executable that checks the migrated schema.
4. Set truthful `migration.revision` and `verification.revision` values, or declare complete content inputs for each hook as below.
5. Make each executable close its database connections before exit.
6. Put shared data in `baseline.fixtures`.
7. Configure optional `clone.preparation` for per-clone state that must be created through domain commands.
8. Put test-specific independent changes in scenario fixtures.

   A scenario can include a base fixture when its captured identity is unchanged.
   Hinagata does not load the shared base fixture twice.
   Service migrations must grant application access to tables and sequences.

## Identify external migration and verification inputs

Use `revision_executable: true` with an absolute executable, `revision_inputs` for every SQL/manifest/code file consumed, and `revision_values` for selected non-secret configuration.
See the complete [configuration example and rules](../user/configuration.md#content-derived-baseline-revisions).
Relative inputs resolve against the hook cwd or invocation directory, never the YAML location.
A manifest does not automatically select its referenced files. Declare the manifest and those files separately, including shared files read by verification.
Pass the same selected paths and values to the commands through explicit argv/environment overlays.
Keep selected inputs stable throughout preparation; concurrent edits can fail checks without providing an atomic snapshot.

The [Keiro driver](../../scripts/keiro-revision-inputs.py) generates paths, a schema-marker command overlay, and identity declarations from the same variables.
It changes external application SQL while proving the migration executable digest stays equal, then observes `Built` followed by `Reused` and queries the added column in a clone.
It independently tests the manifest, executable, verification script/SQL, and consumed marker.
Use a manual revision such as `service-deployment-v12` for remote/secret-controlled effects; do not hash secrets or assume remote state is inspected.
Omitting both authoring modes preserves rebuild-on-each-preparation behavior.
`--check-config` validates declarations offline; only operational preparation reads selected content.

## Seed domain state before service startup

The lifecycle is baseline migration/fixtures/verification → clone/access → preparation command → scenario suffix → application handoff.
The setup endpoint is available to the preparation executable before the service starts.
Use the service's public command/store APIs to create event-backed state and close its pools before exit.
Fixture SQL should not fabricate runtime event, outbox, or workflow rows.

For example, the packaged `hinagata-keiro-seed seeded 2` calls `addCounter` twice.
Configure its executable with `HINAGATA_CLONE_PREPARATION_EXECUTABLE` and use:

```yaml
clone:
  preparation:
    argv: [seeded, "2"]
    environment: []
    deadline_ms: "10000"
```

The complete [configuration reference](../user/configuration.md#per-clone-preparation) shows executable and cwd settings.
Preparation runs once per new clone and does not contribute to baseline identity.
Changing a seed total keeps a truthful unchanged baseline reusable; the next clone receives the new seed.
Omitting preparation preserves the original lifecycle.
A seed failure, deadline, or cancellation prevents service startup.
Bounded supervision releases the database only after process stoppage is proven; otherwise inspect the preserved lease.
The private `PGPASSFILE` supplies setup authentication when needed, and managed variables cannot be overridden by the seed overlay.
The seed executable owns its diagnostic output, which goes to stderr.

PostgreSQL bootstrap, service startup/readiness, and projection workers remain caller responsibilities.
The example's workbench suites later read `/counters/seeded` through HTTP using the application role,
with totals `2` and `5` in separate clones of the same reused baseline.

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
