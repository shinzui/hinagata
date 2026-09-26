# Hinagata（雛形）

> Reproducible PostgreSQL test environments and fixtures for integration and end-to-end testing.

## 1. Overview

**Hinagata** is a CLI for creating, managing, and running disposable PostgreSQL-backed test environments.

It is designed primarily for integration and end-to-end tests where:

- services depend on PostgreSQL;
- tests require realistic and repeatable database state;
- HTTP tests are executed with tools such as Hurl;
- database schemas evolve frequently;
- manually maintaining local test databases is unreliable;
- rebuilding test state from scratch is currently too cumbersome.

Hinagata treats a test database as a **generated artifact rather than persistent development state**.

The fundamental lifecycle is:

```text
Migrations
    ↓
Base Fixtures
    ↓
Canonical Database
    ↓
Snapshot
    ↓
Ephemeral Database
    ↓
Scenario Fixtures
    ↓
Tests
    ↓
Destroy
```

A developer should never need to repair a test database manually.

If the database is corrupted, stale, or otherwise unusable, recreating it should be the normal recovery mechanism.

---

## 2. Name

**Hinagata（雛形 / ひながた）** is a Japanese word meaning a **model, template, pattern, or prototype used as the basis for creating something else**.

The name reflects the central abstraction of the project.

Hinagata maintains known-good representations of application state from which disposable test environments can be instantiated repeatedly:

```text
              雛形
         known-good form
                │
        ┌───────┼───────┐
        ▼       ▼       ▼
      Test A  Test B   Test C
```

A fixture is a *hinagata* for a particular domain state.

The canonical database is a *hinagata* for test databases.

A snapshot is a compiled *hinagata* that can be instantiated efficiently.

The name therefore applies not only to fixture management but to the broader idea behind the project:

> **Define a known-good form once and reproduce it reliably.**

The CLI executable is:

```bash
hinagata
```

---

## 3. Goals

Hinagata should:

1. Make test databases disposable.
2. Reproduce known database states reliably.
3. Make recovery from a broken local database trivial.
4. Separate database construction from database usage.
5. Support reusable and composable fixtures.
6. Detect fixtures broken by schema changes.
7. Make creating an isolated database cheap enough to do routinely.
8. Integrate cleanly with Hurl.
9. Support parallel test execution using isolated databases.
10. Provide a foundation for richer fixture capture and compilation later.

---

## 4. Non-Goals

The initial version of Hinagata is not:

- a database migration framework;
- an ORM;
- a production database management tool;
- a general-purpose test framework;
- a replacement for Hurl;
- a mock server;
- a service orchestration framework;
- a general-purpose data generation framework.

Hinagata should initially delegate rather than duplicate existing tools wherever possible.

---

## 5. Core Principle

### Test Databases Are Disposable

A test database must never contain authoritative state.

The authoritative representation is:

```text
migrations
+
fixtures
+
configuration
```

A database is merely one materialization of those inputs.

Therefore:

```text
Database broken?
       │
       ▼
    Destroy
       │
       ▼
    Rebuild
```

is preferable to:

```text
Database broken?
       │
       ▼
Investigate state
       │
       ▼
Repair manually
```

The most important invariant of Hinagata is:

> Given the same migrations and fixture sources, Hinagata can reproduce an equivalent test environment.

---

## 6. Core Concepts

The initial version defines five primary concepts:

```text
Project
Canonical Database
Snapshot
Fixture
Run
```

---

## 7. Project Configuration

A project defines how Hinagata manages its test environment.

Example:

```yaml
# hinagata.yaml

database:
  host: localhost
  port: 5432
  user: postgres

canonical:
  database: my_service_test

migrations:
  command: cabal run migrations

fixtures:
  path: tests/fixtures

tests:
  path: tests/hurl
```

Hinagata should avoid assuming a particular migration framework.

Instead, migration execution should initially be represented as an external command.

This allows Hinagata to work with:

- custom Haskell migration executables;
- `sqlx`;
- `flyway`;
- `dbmate`;
- `migrate`;
- raw SQL;
- project-specific migration systems.

---

## 8. Canonical Database

Each Hinagata project has a **canonical database**.

For example:

```text
my_service_test
```

The canonical database represents the known-good baseline for test execution.

It contains:

```text
empty PostgreSQL database
        ↓
migrations
        ↓
base fixtures
        ↓
canonical database
```

Tests must never execute directly against the canonical database.

The canonical database exists only to:

- verify database construction;
- produce snapshots;
- create ephemeral databases.

---

## 9. Building the Canonical Database

The command:

```bash
hinagata db build
```

performs:

```text
drop existing canonical database
            ↓
create database
            ↓
run migrations
            ↓
load base fixtures
            ↓
validate
            ↓
ready
```

Example output:

```text
Building my_service_test

  database       created
  migrations     applied
  fixtures       loaded
  validation     passed

Ready in 1.8s
```

---

## 10. Reset

The primary recovery command is:

```bash
hinagata db reset
```

Initially, this may simply be equivalent to:

```bash
hinagata db build
```

The distinction exists because `reset` describes developer intent:

> I do not trust the current database. Give me a known-good one.

Future implementations may optimize reset using snapshots.

---

## 11. Snapshots

Replaying migrations and loading fixtures may eventually become expensive.

Hinagata therefore supports compiling the canonical database into a snapshot:

```bash
hinagata db snapshot
```

The initial implementation should use PostgreSQL's custom dump format:

```bash
pg_dump \
  --format=custom \
  my_service_test \
  > .hinagata/snapshots/base.dump
```

Snapshots are **derived artifacts**.

They are not authoritative fixture sources.

Conceptually:

```text
migrations + fixtures
         │
         ▼
 canonical database
         │
         ▼
      snapshot
```

---

## 12. Snapshot Restoration

A canonical database can be reconstructed from the current snapshot:

```bash
hinagata db restore
```

Conceptually:

```text
base.dump
    ↓
create database
    ↓
pg_restore
    ↓
canonical database
```

This provides a fast path for recovering a known-good environment.

---

## 13. Ephemeral Databases

Tests should execute against ephemeral databases.

An ephemeral database is derived from the canonical state and belongs to one test execution.

Example:

```text
my_service_test
      │
      ├── hinagata_01JQABC
      ├── hinagata_01JQDEF
      └── hinagata_01JQXYZ
```

The command:

```bash
hinagata db clone
```

creates an ephemeral database.

Where possible, the initial implementation should use PostgreSQL database templates:

```sql
CREATE DATABASE hinagata_01JQABC
TEMPLATE my_service_test;
```

This makes creating isolated test environments inexpensive.

---

## 14. Fixture Model

A fixture describes database state layered on top of the canonical database.

The initial implementation should deliberately keep fixtures simple.

The initial supported fixture representation is:

```text
SQL
```

Example:

```text
tests/
└── fixtures/
    ├── base/
    │   └── fixture.sql
    └── scenarios/
        ├── qualified-agent/
        │   └── fixture.sql
        └── multiple-subscriptions/
            └── fixture.sql
```

This keeps the initial implementation small while preserving room for richer fixture representations later.

---

## 15. Base Fixtures

Base fixtures are loaded into the canonical database.

They represent data required by most tests.

Examples include:

- application configuration;
- chapters;
- markets;
- MLS configuration;
- plans;
- permissions;
- stable reference data.

They should avoid scenario-specific state.

The distinction is:

```text
Base Fixture
    ↓
needed by most tests

Scenario Fixture
    ↓
needed by a particular test
```

---

## 16. Scenario Fixtures

Scenario fixtures describe additional state required by a test.

Examples:

```text
qualified-agent
multiple-subscriptions
pending-registration
cancelled-membership
```

They are applied only after an ephemeral database has been created.

Example:

```text
canonical database
       ↓
clone
       ↓
ephemeral database
       ↓
multiple-subscriptions
       ↓
test database
```

---

## 17. Fixture Metadata

A fixture may contain metadata:

```yaml
# fixture.yaml

name: multiple-subscriptions

description: >
  An active member with multiple subscription records
  in different lifecycle states.

include:
  - qualified-agent
```

alongside:

```text
fixture.sql
```

The initial implementation only needs to support:

- `name`;
- `description`;
- `include`.

---

## 18. Fixture Composition

Fixtures may depend on other fixtures.

Example:

```yaml
name: multiple-subscriptions

include:
  - active-agent
```

Hinagata resolves the dependency graph:

```text
active-agent
     ↓
multiple-subscriptions
```

Dependencies are applied before the requesting fixture.

Each fixture must be applied at most once.

Circular dependencies are invalid.

For example:

```text
A → B → C → A
```

must fail before any database mutation occurs.

---

## 19. Loading Fixtures

A fixture can be loaded manually:

```bash
hinagata fixture load multiple-subscriptions
```

Hinagata:

1. resolves dependencies;
2. determines application order;
3. executes fixture SQL;
4. reports failures.

Example:

```text
Loading multiple-subscriptions

  active-agent              loaded
  multiple-subscriptions    loaded

2 fixtures loaded in 84ms
```

---

## 20. Fixture Validation

Fixtures must be continuously validated against the current schema.

```bash
hinagata fixture validate multiple-subscriptions
```

Validation creates an isolated database:

```text
canonical
    ↓
clone
    ↓
fixture dependencies
    ↓
fixture
    ↓
constraint validation
    ↓
destroy
```

The original canonical database remains untouched.

---

## 21. Validate All Fixtures

```bash
hinagata fixture validate --all
```

Example output:

```text
Validating fixtures

  active-agent               ✓
  qualified-agent            ✓
  multiple-subscriptions     ✓
  cancelled-membership       ✗

cancelled-membership

  ERROR: null value in column "cancelled_by"
  violates not-null constraint

3 passed
1 failed
```

This command should be suitable for CI.

---

## 22. Schema Evolution

Fixture validation should make schema evolution explicit.

Suppose a migration adds:

```sql
ALTER TABLE subscription
ADD COLUMN created_by UUID NOT NULL;
```

An incompatible fixture should fail immediately:

```text
✗ multiple-subscriptions

subscription.created_by is NOT NULL

Fixture:
  scenarios/multiple-subscriptions

Database:
  hinagata_01JQABC
```

The desired mental model is:

> A fixture that no longer loads is equivalent to source code that no longer compiles.

---

## 23. Hurl Integration

Hinagata should treat Hurl as an external test runner rather than embedding its behavior.

A test scenario might look like:

```text
tests/
└── hurl/
    └── registration/
        ├── test.yaml
        ├── create.hurl
        ├── profile.hurl
        └── qualify.hurl
```

With:

```yaml
fixture: pending-registration

files:
  - create.hurl
  - profile.hurl
  - qualify.hurl
```

This keeps the fixture lifecycle independent from the HTTP testing implementation.

---

## 24. Running Tests

```bash
hinagata run registration
```

performs:

```text
resolve test
      ↓
resolve fixture graph
      ↓
clone canonical database
      ↓
load fixtures
      ↓
prepare environment
      ↓
execute Hurl
      ↓
collect result
      ↓
drop database
```

Example output:

```text
registration

  database        hinagata_01JQABC
  fixture         pending-registration
  setup           91ms

  create.hurl     ✓
  profile.hurl    ✓
  qualify.hurl    ✓

3 passed
1.4s
```

---

## 25. Environment

Hinagata should expose the ephemeral database to the test runner through environment variables.

At minimum:

```text
HINAGATA_DATABASE
HINAGATA_DATABASE_URL
HINAGATA_RUN_ID
```

For example:

```text
HINAGATA_DATABASE=hinagata_01JQABC
HINAGATA_DATABASE_URL=postgresql://localhost/hinagata_01JQABC
HINAGATA_RUN_ID=01JQABC
```

The Hurl runner and application services can consume these values.

---

## 26. Run Identity

Every execution receives a unique run identifier.

Example:

```text
01JQAX9XM9RK...
```

This identifier is used for:

- database names;
- temporary directories;
- logs;
- diagnostics.

Example:

```text
.hinagata/
└── runs/
    └── 01JQAX9XM9RK/
        ├── environment
        ├── hurl.log
        └── run.yaml
```

---

## 27. Failed Tests

By default, successful test databases should be destroyed.

For failures, Hinagata should support:

```bash
hinagata run registration --preserve-on-failure
```

Example:

```text
registration

  create.hurl     ✓
  profile.hurl    ✓
  qualify.hurl    ✗

FAILED

Environment preserved.

Run:
  01JQABC

Database:
  hinagata_01JQABC

Inspect:

  hinagata shell 01JQABC
```

This makes the exact failing state available for investigation.

---

## 28. Shell

Hinagata should provide:

```bash
hinagata shell
```

to open `psql` against the current development test database.

A preserved run can be inspected with:

```bash
hinagata shell 01JQABC
```

This executes approximately:

```bash
psql "$HINAGATA_DATABASE_URL"
```

---

## 29. Cleanup

Interrupted processes may leave ephemeral databases behind.

Hinagata should provide:

```bash
hinagata clean
```

This removes abandoned:

- ephemeral databases;
- run directories;
- temporary files.

The implementation must avoid deleting databases it cannot positively identify as Hinagata-managed.

---

## 30. Parallel Execution

The architecture should support parallel execution from the beginning even if sophisticated scheduling is deferred.

Each test receives an independent database:

```text
canonical
    │
    ├── registration      → hinagata_A
    ├── subscriptions     → hinagata_B
    └── mls               → hinagata_C
```

Therefore test isolation is provided by PostgreSQL rather than coordination between tests.

A future command may support:

```bash
hinagata run --all --parallel
```

---

## 31. Project Layout

Recommended initial layout:

```text
hinagata.yaml

tests/
├── fixtures/
│   ├── base/
│   │   └── fixture.sql
│   │
│   └── scenarios/
│       ├── active-agent/
│       │   ├── fixture.yaml
│       │   └── fixture.sql
│       │
│       ├── qualified-agent/
│       │   ├── fixture.yaml
│       │   └── fixture.sql
│       │
│       └── multiple-subscriptions/
│           ├── fixture.yaml
│           └── fixture.sql
│
└── hurl/
    ├── registration/
    │   ├── test.yaml
    │   └── registration.hurl
    │
    └── subscriptions/
        ├── test.yaml
        └── subscriptions.hurl

.hinagata/
├── snapshots/
└── runs/
```

`.hinagata/` should generally be ignored by Git.

Fixture sources should be committed.

---

## 32. Determinism

Fixtures should be deterministic.

Given:

```text
same migrations
+
same configuration
+
same fixtures
```

Hinagata should construct an equivalent database state.

Fixtures should therefore avoid unnecessary dependence on:

- wall-clock time;
- random identifiers;
- machine-specific values;
- external services;
- mutable production data.

Where generated identifiers are necessary, deterministic test identifiers should be preferred.

---

## 33. Safety

Hinagata performs destructive database operations.

It must therefore have strong safety boundaries.

Hinagata should refuse destructive operations unless the target database can be positively identified as a Hinagata-managed test database.

Production-like hostnames or explicitly protected databases should be rejected.

Configuration should support:

```yaml
database:
  allowed_hosts:
    - localhost
    - 127.0.0.1
```

A database should also be recognizable through a configured prefix:

```yaml
database:
  ephemeral_prefix: hinagata_
```

Hinagata should prefer refusing an operation over risking deletion of an unknown database.

---

## 34. Initial CLI

The initial public CLI should remain intentionally small.

```text
hinagata
│
├── db
│   ├── build
│   ├── reset
│   ├── snapshot
│   ├── restore
│   └── clone
│
├── fixture
│   ├── load
│   └── validate
│
├── run
├── shell
└── clean
```

Commands such as fixture capture, diff, update, event loading, and domain-level fixture compilation should be added only after the fundamental lifecycle is proven.

---

## 35. Initial Implementation Scope

The first implementation should support:

### Configuration

- `hinagata.yaml`;
- PostgreSQL connection information;
- canonical database
