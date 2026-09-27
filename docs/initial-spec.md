# Hinagata（雛形）

Reproducible PostgreSQL fixtures and disposable test databases for Haskell services.

## Purpose and scope

Hinagata is a Haskell library with a thin CLI. It prepares state for integration tests, including those driven by `mori://shinzui/hurl-workbench`, using PostgreSQL that the service or test harness has already bootstrapped. Local Unix sockets are a first-class connection mode. No additional server or container is required.

Support both direct fixture loading into an explicitly selected caller-owned test database and isolated databases cloned from a reusable baseline on the same server. Loading fixtures never transfers database ownership. Hinagata never automatically drops, resets, or truncates a caller-owned database.

The first release must handle both small scenarios and large bulk loads, as requested by the user. Performance includes repeated setup latency, bulk throughput, bounded client memory, and bounded concurrency.

This revision supersedes the earlier CLI-first spec. Hurl composition, execution, reports, service startup, and readiness belong to hurl-workbench or the caller. Dump snapshots/restore, capture, schema diffing, automatic event generation, a daemon, and PostgreSQL provisioning are deferred. Initial reset means obtaining a fresh owned clone. Template cloning replaces dump/restore in the hot path.

## Architecture and ownership

```text
Caller-owned PostgreSQL (Unix socket or explicit TCP endpoint)
  ├── Existing migrated test database → fixture load → caller runs tests
  └── New baseline → migrations → base fixtures → verification → seal
       └── Clone → scenario fixtures → commit → service/test handoff
            └── stop service and close pools → release or preserve clone
```

A baseline is a validated database used only as a template. A lease is an exclusive handle to one owned database and its cleanup responsibility. A run groups leases and diagnostics under a unique identifier. The caller owns all servers and service processes. Hinagata owns only the databases it creates and positively records.

Use three packages: `hinagata-core` for pure fixture planning, identifiers, errors, connection descriptions, and Settei declarations; `hinagata-postgres` for execution and database lifecycle; `hinagata-cli` for source loading, parsing, output, and command handoff. Expose Hinagata-owned endpoint values, not Hasql, Keiro, Kiroku, or libpq handles. No consumer must adopt Hinagata's driver or effect system.

The PostgreSQL package uses `postgresql-libpq` behind a private exclusive-session adapter for SQL and streaming COPY on the same connection. The adapter owns connection lifetime, result draining, cancellation, and protocol recovery. Package bounds must follow a verified released compiler/dependency cohort, not versions copied from local guides.

Provide bracketed library operations: acquire a session or lease, invoke a callback, and release after success, failure, or cancellation. Expected operational failures are typed values. Unexpected and asynchronous exceptions propagate after cleanup. Preserve the primary failure alongside cleanup diagnostics. Abrupt process death is handled through recorded ownership and explicit recovery.

Retain compiled plans and opaque baseline references across a suite. A bracketed, suite-scoped manager bounds concurrent setup, active leases, and pending acquisition requests without requiring a daemon. Waiting is cancellable and consumes the same acquisition deadline as lock waits and setup. Limits are local to that manager; callers sharing a cluster budget aggregate concurrency and application connection pools. Report queue saturation and timeout phases explicitly.

A lease callback may return a test failure as a value. Provide an explicit result classifier for success/failure so preserve-on-failure does not depend solely on exceptions or a particular test framework. Cancellation remains a distinct outcome; cleanup cannot replace the original result or exception.

## Connection and configuration

Represent Unix socket directory and TCP host as distinct choices, with explicit port, user, database, optional secret credentials, and deadlines. A socket directory is the libpq `host` value. Socket failure must never silently fall back to TCP. Render correctly escaped libpq keyword connection strings and explicit child variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`), not a socket path embedded as a URL hostname. Secret-bearing values have redacted displays.

Separate administration, setup, and application access descriptions. The administration target manages the maintenance catalog and database lifecycle; setup credentials run migrations/fixtures; the application endpoint is handed to consumers. Roles already exist through service bootstrap. Never silently hand administrative credentials to the application. A caller may explicitly choose the same role for several purposes; ordinary examples use application permissions representative of the service.

Use Settei for settings. CLI precedence is built-ins, explicit YAML files in occurrence order, explicitly bound environment variables, then `--set KEY=VALUE` occurrences. Initially use the direct YAML adapter and `--config PATH`. The library takes resolved values and does not implicitly inspect files or the environment. Fixture manifests are strictly decoded source data, not an alternative settings system.

Support `--describe-config`, `--describe-config-json`, `--explain-config`, `--explain-config-json`, and `--check-config`, without database mutation. Usage errors exit 2, source errors 3, resolution errors 4, and operational failures 1. Generic command handoff preserves child exit status and identifies the failure phase in diagnostics.

## Fixture model

A fixture is a named directory under a configured root, with optional `fixture.yaml` and ordered steps. A directory containing only `fixture.sql` defines one SQL step named after the directory. An explicit manifest looks like this:

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

COPY initially supports UTF-8 PostgreSQL CSV with comma delimiter, standard quoting/null rules, and explicit header presence. Reject unknown options. Validate and quote schema, table, and column identifiers separately. Stream local files through `COPY ... FROM STDIN`; never ask the server to read a client file or execute a program. Binary COPY and custom formats are deferred.

Resolve requested roots in caller order and includes in declared order, with dependencies first and each fixture once per plan. Report the complete cycle path. Reject missing dependencies, duplicate names, unknown fields, invalid identifiers, and paths escaping the fixture root, including symlinks, before database mutation. `validate --all` tests each scenario in its own clone with its own closure.

Compile into an immutable private local bundle containing ordered steps and content digests. Copy and hash sources in bounded chunks; SQL steps have a configurable size limit and CSV stays file-backed. Execution reads frozen bytes, so edits during a run cannot invalidate the fingerprint. Compilation is explicit and reusable. Persistent bundle reuse verifies integrity; path/mtime alone is insufficient. Bundles are disposable derived artifacts.

SQL is trusted project code, not a sandbox. Fixtures must use transaction-compatible SQL without psql commands, transaction control, or inline COPY data. Preflight uses a PostgreSQL-aware lexical scan handling strings, identifiers, nested comments, and dollar quotes to reject prohibited top-level statements; do not split naively on semicolons or rewrite SQL with regular expressions. PostgreSQL performs complete syntax/type/constraint validation.

## Execution and bulk loads

Execute the full closure, including SQL and CSV steps, in one transaction on one exclusively borrowed connection. Enforce lock and statement deadlines, keep constraints/triggers enabled, and report commit-time failures. Stream CSV with bounded buffers and backpressure; never materialize all rows or issue an INSERT per row. Large data belongs in CSV steps rather than enormous SQL strings.

Drain every PostgreSQL result, including COPY completion. On malformed CSV, SQL failure, disconnect, deadline, or cancellation, roll back or discard a connection whose protocol state cannot be recovered. Never reuse a connection left in COPY mode. Rollback covers transactional writes; PostgreSQL sequence advancement and external effects are outside this guarantee. Direct loading requires exclusive caller control and deterministic fixture IDs for reproducibility.

When explicit fixture IDs affect later generated IDs, fixture authors supply schema-aware sequence SQL and verify a subsequent application insert. Hinagata does not infer or rewrite sequence ownership. Bulk examples declare their ANALYZE policy as explicit fixture SQL before sealing/handoff and report its time separately from transfer; direct loading never silently analyzes unrelated tables.

Deduplication applies within one plan, not across calls. A repeated load executes again and may fail on uniqueness constraints. Use a new clone or deliberately idempotent fixture SQL to rerun.

## Baseline construction and reuse

A sealed baseline is the initial snapshot mechanism: it materializes migrations and a chosen fixture closure once, then clones that state without replaying or reloading it. Projects may prepare several baseline variants, including a large frequently reused scenario as the base closure, keyed by their input fingerprints. Cloning still copies database data and is not a constant-time filesystem snapshot. Portable `pg_dump` artifacts for restoring onto a fresh cluster are deferred; reuse initially lasts for the life of the existing cluster.

For a known baseline, resolve one combined graph with its base roots first and scenario roots second. The frozen base closure is a prefix of that order. Execute only the remainder on a fresh clone; shared fixture names must match the baseline's captured definition and content identity, including includes and COPY options. Reject conflicts before allocating. No baseline-aware skipping applies to direct loads or arbitrary previously used databases. A prepared baseline reference amortizes hashing, but acquisition still revalidates catalog/database identity and sealed state.

Create a fresh generation from `template0`, invoke the application migration hook, load base fixtures, verify, close all connections, disable baseline connections, and publish. Failed construction never publishes an incomplete baseline or destroys the last valid generation. Clone from a separate maintenance connection outside a transaction.

The migration/verification hooks accept a target endpoint. They can invoke public Haskell APIs or an executable plus argv, working directory, explicit environment, and deadline. Never implicitly evaluate shell text. The application supplies one complete migration plan. Hinagata does not invent writes to private Keiro/Kiroku/PGMQ tables.

A baseline fingerprint covers format version, project identity, explicit migration revision, ordered base-bundle digests, non-secret schema-affecting configuration, PostgreSQL major version, and extension/locale requirements. Opaque command text is not a migration identity: include embedded migration/build inputs, or rebuild rather than persistently reuse. Include non-secret owner/setup/application role identities, declared grants/settings, and revisions for state-affecting hooks. Secrets and password-derived digests are not fingerprint inputs. An unversioned state-affecting hook also prevents persistent reuse.

Keep a versioned fingerprint manifest and report reuse/build reasons and changed input categories against a selected previous generation. Distinguish first construction, changed inputs, unknown revision, and invalid database identity. Expose phase timings without SQL/CSV payloads. Concurrent waiters observe Ready or a failed generation; cancellation of a waiter does not cancel another caller's builder, and failed builds permit an explicit later retry.

Scope reuse to a cluster identity stored in a Hinagata-owned maintenance catalog. Verify recorded database identity; server restart retains catalog identity, cluster recreation invalidates it. Do not require superuser-only cluster inspection. Serialize construction per fingerprint using an advisory lock, record allocation intent before CREATE DATABASE, bind actual identity afterward, and publish atomically. Handle ambiguous crash windows by inspection rather than guessing from a prefix. Coordinate acquisition, baseline retirement, and cleanup under the same locking protocol.

A template must have no connected sessions. Never terminate caller-owned sessions to clone their database. Database-level grants and settings do not copy with templates: reapply declared settings/grants and invoke an optional application-owned clone preparation hook before fixture loading/handoff. Global roles and extension installation privileges remain the service bootstrap's responsibility.

## Isolation and cleanup

Commit fixture state before starting the service: another process cannot see an uncommitted setup transaction. Each concurrent scenario needs a separate clone and service instance or an application-defined isolation boundary. Changing Hinagata's environment cannot retarget a running service. Multiple services can use a named collection of leases; failed acquisition compensates earlier allocations. No cross-database transaction is promised.

Positive ownership combines a project-scoped maintenance record, database name/OID, ownership marker, and cluster identity. A prefix, localhost, or a socket alone never authorizes deletion. Borrowed and protected maintenance/template databases never qualify.

Active leases hold a maintenance-session advisory lock. Cleanup must acquire that lock, recheck identity, and skip active/preserved leases. Preservation records retained state. Detached acquisition records a persistent explicit lease instead of becoming abandoned when the CLI exits. Cleanup previews by default and applies only with an explicit flag; preserved resources require explicit selection. Forceful dropping is limited to positively owned clones after consumers stop. Retain metadata and report PostgreSQL refusals.

## CLI and hurl-workbench handoff

Expose `fixture plan`, `fixture load`, `fixture validate`, `db prepare`, `db acquire`, `db release`, `db with`, `inspect`, and `clean`. Commands call library operations and provide versioned JSON where useful.

`db with --fixture NAME -- PROGRAM ARGS...` obtains a clone, loads fixtures, overlays explicit connection variables and `HINAGATA_RUN_ID`, invokes one generic command, waits for shutdown, then releases or preserves. A service-specific wrapper maps the endpoint into its Settei settings and invokes hurl-workbench. Hinagata owns this wrapper's process group to keep the lease valid through interruption; hurl-workbench owns service readiness, HTTP execution, and reports. Add no Hurl-specific flags or workspace hooks.

Detached `db acquire` emits an opaque lease ID and non-secret endpoint fields. `db release ID` checks identity again. `inspect ID` supports retained/detached resources. Credentials travel only through explicit secret channels, never normal JSON or shell-evaluated output. A suite-level workbench service has one stable endpoint; isolated parallel scenarios use separate suite invocations and service instances.

## Haskell conventions and acceptance

Bootstrap the development environment with `mori://shinzui/seihou-modules/templates/nix-haskell-flake`. Preserve its managed canonical lock and generated files; place workspace-specific outputs/tools in `flake.module.nix`, with local environment/process overrides in their supported unmanaged files.

Follow `mori://shinzui/haskell-jitsurei/docs/core-standards`, `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`: GHC >=9.12, GHC2024, baseline extensions, strict unprefixed fields, explicit deriving, postpositive qualified imports, and a small `Hinagata.Prelude`. Keep generic-lens label orphans out of the prelude/public definition modules and `PackageImports` local to the prelude. Follow `mori://shinzui/keiro-runtime-patterns/docs/config-settei-cli-standard` for settings.

Acceptance includes deterministic graphs, socket direct loading, SQL/COPY rollback and cancellation, clone isolation under concurrency, baseline invalidation, cleanup identity refusal, Settei precedence/redaction, and a runnable Keiro service example tested through hurl-workbench. Distinguish migration-ledger verification from owner-supplied live-schema verification.

Benchmark 100/1,000-row scenarios and 100,000/1,000,000-row CSV fixtures. Separate cold compilation/build, warm reuse, cloning, loading, cleanup, and end-to-end cost. Record median/p95, rows/second, allocation, maximum client residency, and machine/toolchain/PostgreSQL/storage details. Compare against equivalent single-session `psql` SQL/COPY and full database rebuilding on identical inputs. Measure queue/lock waiting and the total connection budget, including lease guards and application pools. If cloning dominates, evaluate a bounded spare-clone experiment with full preparation/storage costs before proposing a pool; initial acquisition creates fresh clones on demand.

Proposed release gates: bulk COPY within 25% of `psql` elapsed time; no more than 64 MiB additional client residency for tenfold bulk input growth; warm small-scenario setup under 250 ms median/500 ms p95 on the documented reference machine. These are targets, not measurements. If infeasible, record evidence and explicitly revise the gate before declaring completion. Never silently disable durability globally to meet a target.

The [MasterPlan](masterplans/1-build-hinagata-for-fast-postgresql-fixtures-and-isolated-microservice-tests.md) coordinates implementation. [Initial research](research/initial-design.md) records dependency observations; the [prior-art review](research/prior-art.md) records source evidence and adopted/deferred ideas. No implementation exists yet.
