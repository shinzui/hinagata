# Hinagata（雛形）

Reproducible PostgreSQL fixtures and disposable test databases for Haskell services.

> **Status:** planning. The design, ADRs, and implementation plans are written; no code exists yet.

## The name

*Hinagata* (雛形) is Japanese for a **template**, **model**, or **pattern**. It is also the word for a scale model or a blank form you fill in. The first character, 雛 (*hina*), means a chick or a small doll, as in *hina ningyō*, the dolls displayed for Hinamatsuri. It suggests something small and young. The second, 形 (*kata/gata*), means shape or form. Put together, the word means a small, faithful form that you copy from.

That is how the tool works:

- **The template is the baseline.** Hinagata builds a database once by running migrations and loading base fixtures, then verifies it and *seals* it. After that the baseline is used only as a PostgreSQL template (`CREATE DATABASE … TEMPLATE …`). It is never used directly.
- **Every test gets a copy of the template.** Each scenario clones the sealed baseline, loads its own fixtures on top, and hands the result to the service under test. Clones stay separate from each other, and cleaning up after a test means throwing its clone away.
- **Fixtures are small models of the world.** A fixture is a named, versioned description of the state a test should start from. Loading it always gives the same result. It is like a blank form that each test fills in the same way.

In the spec's words, cloning a template "replaces dump/restore in the hot path." The mold is made once and then copied many times.

## What it does

Hinagata is a Haskell library with a thin CLI. It prepares database state for integration and end-to-end tests. It works against a PostgreSQL server that your service or test harness has already started, and it treats a local Unix socket as a first-class way to connect. It does not need an extra server, container, or daemon.

It supports two modes:

1. **Direct loading.** Load fixtures into a test database that you own and select explicitly. Hinagata never takes ownership of that database and never drops, resets, or truncates it on its own.
2. **Isolated clones.** Build a reusable baseline once, then lease fresh clones of it. Hinagata owns only the databases it creates and records, and it deletes a database only after confirming it created that database.

```text
Caller-owned PostgreSQL (Unix socket or explicit TCP endpoint)
  ├── Existing migrated test database → fixture load → caller runs tests
  └── New baseline → migrations → base fixtures → verification → seal
       └── Clone → scenario fixtures → commit → service/test handoff
            └── stop service and close pools → release or preserve clone
```

### Fixtures

A fixture is a directory under a configured root. The directory can hold a single `fixture.sql`, or a `fixture.yaml` manifest that lists includes and ordered steps:

```yaml
name: subscribed-members
description: Stable members with subscriptions
include:
  - reference-data
steps:
  - sql: prepare.sql
  - copy:
      table: { schema: app, name: members }
      columns: [id, email]
      file: members.csv
      format: csv
      header: true
  - sql: subscriptions.sql
```

- Includes are resolved in a fixed order, dependencies first, and each fixture runs only once. Cycles, missing fixtures, invalid identifiers, and paths that escape the fixture root are all rejected before anything touches the database.
- Fixtures are compiled into a frozen local bundle that records a digest of each file's contents. Editing files during a run cannot change what gets loaded.
- The whole closure runs in **one transaction on one connection**. CSV data is streamed with `COPY … FROM STDIN` using bounded buffers, so memory stays bounded, and any failure rolls everything back.

### Baselines and leases

- A **baseline** has a fingerprint covering its inputs: migration revision, fixture digests, PostgreSQL version, and relevant settings. It is reused while the inputs stay the same and rebuilt when they change. The reason for a rebuild is reported.
- A **lease** gives exclusive use of one cloned database and makes the holder responsible for cleaning it up. A **run** groups leases and diagnostics under a unique ID.
- A suite-scoped manager limits concurrent setup and active leases. A clone can be kept after a failed test so you can inspect it. Cleanup shows a preview by default and only deletes when you pass an explicit flag.

### CLI

`fixture plan | load | validate`, `db prepare | acquire | release | with`, `inspect`, and `clean`.

`db with --fixture NAME -- PROGRAM ARGS...` leases a clone, loads fixtures, and runs a command with explicit `PGHOST`/`PGPORT`/`PGUSER`/`PGDATABASE`, `HINAGATA_RUN_ID`, and `HINAGATA_LEASE_ID` variables. When the command exits, it releases or keeps the clone. HTTP test suites run through hurl-workbench (`mori://shinzui/hurl-workbench`), which handles service startup, Hurl execution, and reports. Hinagata only provides the database lease around that workflow.

Configuration uses Settei (`mori://shinzui/settei`). Settings are applied in this order: built-in defaults, YAML files, bound environment variables, then `--set` overrides. Secrets are redacted wherever they are displayed.

## Packages (planned)

| Package | Responsibility |
|---|---|
| `hinagata-core` | Pure fixture planning, identifiers, errors, connection descriptions, Settei declarations |
| `hinagata-postgres` | Execution (SQL + streaming COPY via `postgresql-libpq`) and database lifecycle |
| `hinagata-cli` | Source loading, parsing, output, command handoff |

The public API uses Hinagata's own endpoint types, not Hasql, Keiro, Kiroku, or libpq handles. Consumers do not have to adopt Hinagata's database driver or effect system.

## Out of scope (for now)

The first release does not include: portable `pg_dump` snapshots, data capture, schema diffing, automatic event generation, a daemon, starting or provisioning PostgreSQL, or Hurl-specific behavior.

## Documentation

- [Initial spec](docs/initial-spec.md): the behavioral contract.
- [MasterPlan](docs/masterplans/1-build-hinagata-for-fast-postgresql-fixtures-and-isolated-microservice-tests.md): coordinates the five implementation plans:
  1. [Compile deterministic fixture plans and typed configuration](docs/plans/1-compile-deterministic-fixture-plans-and-typed-configuration.md)
  2. [Load SQL fixtures atomically into existing PostgreSQL databases](docs/plans/2-load-sql-fixtures-atomically-into-existing-postgresql-databases.md)
  3. [Manage reusable baselines and isolated database leases](docs/plans/3-manage-reusable-baselines-and-isolated-database-leases.md)
  4. [Expose fixture commands and hurl-workbench handoff](docs/plans/4-expose-fixture-commands-and-hurl-workbench-handoff.md)
  5. [Prove Keiro service integration and performance](docs/plans/5-prove-keiro-service-integration-and-performance.md)
- ADRs:
  - [1: Library boundary and service-owned PostgreSQL](docs/adr/1-library-boundary-and-service-owned-postgresql.md)
  - [2: Stream fixtures through private PostgreSQL sessions](docs/adr/2-stream-fixtures-through-private-postgresql-sessions.md)
  - [3: Sealed baselines and positive database ownership](docs/adr/3-sealed-baselines-and-positive-database-ownership.md)
- Research:
  - [Initial design](docs/research/initial-design.md)
  - [Prior art](docs/research/prior-art.md)
  - [Haskell standards audit](docs/research/haskell-standards-audit.md)
