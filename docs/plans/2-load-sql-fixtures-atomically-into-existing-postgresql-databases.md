---
id: 2
slug: load-sql-fixtures-atomically-into-existing-postgresql-databases
title: "Load SQL fixtures atomically into existing PostgreSQL databases"
kind: exec-plan
created_at: 2026-09-26T23:47:59Z
intention: "intention_01m3g1rc9re2qa1cy17q25qfq8"
master_plan: "docs/masterplans/1-build-hinagata-for-fast-postgresql-fixtures-and-isolated-microservice-tests.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T23:47:59Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T00:16:29Z
      mode: "update"
      note: "Incorporate prior-art source review into contracts and acceptance."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T04:33:49Z
      mode: "update"
      note: "Audit applicable haskell-jitsurei standards and make missing acceptance requirements explicit."
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T00:30:12Z
      mode: "update"
      note: "House the first load benchmark in a hinagata-postgres benchmark component"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-10-02T05:59:39Z
      mode: "implement"
      note: "Begin EP-2 native PostgreSQL loader implementation"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T00:27:54Z
      verdict: "comments"
      note: "Sound; give the first load benchmark a home that EP-5 aggregates"
---

# Load SQL fixtures atomically into existing PostgreSQL databases

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update relevant ADRs when durable decisions change.


## Purpose / Big Picture

A caller can load a compiled fixture plan into its existing migrated PostgreSQL database over a Unix socket, using SQL for small scenarios and streamed CSV for large datasets. Loading uses one transaction and one reusable native connection, with reliable rollback, bounded memory, and cancellation. It grants no authority to delete or reset the target.


## Progress

- [x] 2026-10-01: SQL closures load and roll back as one transaction over socket and explicit TCP connections. The disposable socket-only suite proves a late SQL error leaves the original sentinel and no partial writes; a missing socket does not fall back to TCP. `just test-postgres` and `just test-postgres-tcp` pass.
- [x] 2026-10-01: CSV COPY shares the transaction, streams 64 KiB chunks, and reports final-result failures. Mixed SQL/COPY/SQL, late duplicate rows, a trigger failure after all COPY bytes, deferred COMMIT failure, and a changed bundle are covered by the integration suite.
- [x] 2026-10-01: Session reuse, retirement, cancellation, and direct-load costs are verified. The suite covers clean reuse after rollback, concurrent/closed use refusal, server disconnect, and interrupted COPY with no active loader after cleanup. The 100k/1m-row benchmark measured 150/1791 ms load time and 220,936/220,832 bytes maximum GHC heap residency on aarch64-darwin with GHC 9.12.4 and PostgreSQL 18.6.


## Surprises & Discoveries

`postgresql-libpq` was absent from the local Mori registry. Hackage's current 0.11.0.0 revision and the upstream `v0.11.0.0` release tag agreed, so the package bounds use `>=0.11 && <0.12`; the released source was inspected before adapting its nonblocking query/COPY calls. Multi-result SQL can otherwise retain a large SELECT result even when the caller discards it, so the adapter requests single-row mode immediately after dispatch and drains each result. Bundle verification before mutation is supplemented by a second SQL digest check immediately before dispatch and an incremental CSV digest check during transfer.

Haddock builds the public library HTML with 100% symbol coverage for the exposed PostgreSQL modules. The core package's separate Haddock coverage remains an improvement opportunity.


## Decision Log

2026-09-26: Use a private `postgresql-libpq` adapter rather than expose a Hasql generation in the API. Treat SQL/CSV as one ordered transactional plan. Use one connection per active load; never spawn a client per fixture or parallelize dependent steps inside a transaction.

2026-09-30: House the first direct-load benchmark as a Cabal benchmark component of `hinagata-postgres` so the final plan's `bench/` driver aggregates it instead of redefining it.


## Outcomes & Retrospective

The `hinagata-postgres` package loads a frozen plan into an existing migrated database through one exclusive, nonblocking native connection and one transaction. It returns secret-safe staged failures, retires ambiguous sessions, and reports verified bytes and stage timings. `just check` passed core and PostgreSQL package tests, formatting, both source distributions, and local aarch64-darwin Nix checks; `cabal haddock hinagata-postgres --haddock-internal` generated HTML. The socket-only and explicit TCP integration suites passed separately. The benchmark results above are an initial local baseline, not a cross-machine performance target. Mori registration now lists `mori://shinzui/hinagata/packages/hinagata-postgres`.


## Context and Orientation

Hard dependency: `docs/plans/1-compile-deterministic-fixture-plans-and-typed-configuration.md` supplies validated endpoints, immutable plans, and build gates. Own `hinagata-postgres/hinagata-postgres.cabal`, `hinagata-postgres/src/Hinagata/Postgres/{Session,Load,Error}.hs`, private `Internal/{Libpq,Sql,Copy}.hs`, and `hinagata-postgres/test/{Main,LoadSpec,CopySpec}.hs`. Add a reusable integration-test harness under `test-support/` that starts one disposable socket-only PostgreSQL cluster for tests; production library code never starts it.

[ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md) forbids lifecycle ownership of borrowed databases. [ADR 2](../adr/2-stream-fixtures-through-private-postgresql-sessions.md) requires SQL/COPY on one exclusive connection. A transaction groups writes until COMMIT; on failure ROLLBACK removes transactional changes but not sequence advancement or external side effects. COPY is PostgreSQL's streaming row-input protocol, not a series of INSERTs.

All paths below are repository-relative and proposed unless explicitly described as existing. At planning time only `docs/initial-spec.md`, project metadata, and planning tools existed. The specification now describes the intended library. Dependency research is in `docs/research/initial-design.md`; discover dependency source with Mori before using APIs, then verify current releases with package registries and upstream tags before selecting bounds. Never search the filesystem root or `/nix/store`.

Follow GHC >=9.12, GHC2024, strict unprefixed records, explicit deriving strategies, postpositive qualified imports, and the project prelude. Keep generic-lens orphan imports out of public type-definition modules and the prelude. These conventions come from `mori://shinzui/haskell-jitsurei/docs/core-standards`, `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`.

Every library, executable, test, and benchmark component imports its package's `common common` baseline with GHC2024 and DeriveAnyClass/DuplicateRecordFields/OverloadedLabels/OverloadedStrings. Use generic-lens labels consistently for record access/updates; construction and constructor-directed patterns are valid. Import `Data.Generics.Labels ()` plainly only where required, and inspect transitive imports so public facades do not leak the orphan. Keep entity IDs first in command/event payloads where applicable. Operators stay unqualified; hide clashing prelude exports.

Use MultilineStrings for suitable embedded multiline text per `mori://shinzui/haskell-jitsurei/docs/core-multiline-strings`, preserving external fixture bytes. The [standards audit](../research/haskell-standards-audit.md) records applicability and acceptance ownership. Expected errors are typed; resource cleanup must run on asynchronous exceptions without swallowing them.


## Plan of Work

### Milestone 1: Direct atomic SQL loading

Verify current `postgresql-libpq` release, upstream tag, source, and toolchain compatibility. Mori had no registered source at planning time; use the upstream source linked in `docs/research/initial-design.md` after repeating Mori discovery. Implement connection acquisition/closure with an opaque session whose internal state prevents concurrent use and use after close. No raw libpq handle escapes. Endpoint failures are typed and socket failure does not retry TCP.

On each `loadPlan`, require exclusive use of an idle connection, begin one transaction, set local statement/lock deadlines, execute frozen SQL in plan order, inspect every result, and commit only after all steps succeed. Keep original SQL intact for line/position diagnostics. Check commit results for deferred constraints. An existing transaction is refused rather than committed or rolled back on the caller's behalf. Borrowing here means borrowing a Hinagata session for an operation, not stealing a consumer's Hasql pool handle.

Implement structured errors carrying phase, fixture, step, safe target identity, SQLSTATE, and original-versus-cleanup failure. Keep raw row contents and secret connection fields out of routine errors; detailed server messages may contain data and require an explicit diagnostic policy. Validate on a fresh test table with two dependent inserts and a failing last step: no inserted rows remain, and the preexisting sentinel is unchanged.

### Milestone 2: Streaming CSV in the same transaction

Render COPY with independently quoted validated identifiers and a fixed CSV format. Open only the compiled bundle file and stream fixed-size strict ByteString chunks. Respect `CopyInWouldBlock`, wait for socket readiness without busy-spinning, flush queued output, terminate COPY, and drain all final results. Do not collect result rows or CSV in memory. Maintain connection serialization across the whole operation. Compare row counts and deterministic checksums after mixed SQL→COPY→SQL steps.

Test bad quoting/type/constraint errors late in a large file, a missing/corrupted bundle, and a final server error delivered after all bytes were sent. Every case must fail and roll back the whole closure. Keep constraints and triggers enabled. Successful load reports fixture/step counts, bytes sent, and stage timings without claiming rows solely from line counts (CSV fields may contain newlines).

### Milestone 3: Cancellation and trustworthy reuse

Use libpq's nonblocking query/COPY operations with a single protocol owner and bounded IO deadlines. Ensure Haskell cancellation can interrupt a blocked network operation. On interruption, abort COPY if possible, drain, and roll back; if recovery is uncertain, close and permanently invalidate the session. Cleanup is bounded and asynchronous exceptions are rethrown. Session reuse must not execute a new command until prior results are exhausted.

Add the test fixture runner `scripts/test-postgres.sh` and `just test-postgres`, with private temporary directories, TCP disabled, safe trap cleanup, and a caller-supplied existing socket mode. Tests cover a socket directory containing spaces, server disconnect, cancellation during COPY, two simultaneous operations on one session, reuse after rollback, and refusal after closure. Collect a first direct-load benchmark as a Cabal benchmark component under `hinagata-postgres/bench/`, which the final integration plan's `bench/` driver reuses, so regression investigation begins before the CLI exists.


Fixture examples must cover a deterministic explicit-ID load followed by an application insert using a generated ID. Authors supply any necessary schema-qualified sequence adjustment as ordinary fixture SQL; do not infer it in the loader. Demonstrate an explicitly requested ANALYZE step after bulk COPY, accounting for its elapsed time separately. Confirm statement ordering and retain the documented nontransactional sequence caveat. These examples adopt the [prior-art review](../research/prior-art.md) without adding a reset or schema-rewriting subsystem.

## Concrete Steps

Run from the Hinagata repository root. The commands below are acceptance interfaces to create in this plan or consume from its prerequisites; they are not claimed to work in the original documentation-only tree.

```bash
nix develop -c cabal build hinagata-postgres
nix develop -c just test-postgres
nix develop -c cabal test hinagata-core-test --test-show-details=direct
nix develop -c just check
```

The socket-only test cluster has no TCP listener and both a SQL plan and a mixed CSV plan succeed. A fixture error leaves original rows intact and no partial fixture writes. Deferred-constraint failure at COMMIT is reported as failure. Cancel a slow COPY and observe no active loader connection within the configured cleanup deadline; reuse either succeeds on a known-good session or returns SessionClosed. The first memory probe loads 100,000 and 1,000,000 rows without retaining the whole input. Borrowed targets survive every error path and teardown.


## Validation and Acceptance

Acceptance requires the observable results above, passing focused tests, and the repository checks appropriate to the completed components. Record concise evidence here and in Progress; do not report planned commands as executed. Build documentation from the exposed library API and keep examples runnable. Update dependency metadata and check source distributions when adding a package or public module.


## Idempotence and Recovery

Retry only after rollback on a recovered session or after opening a fresh session. Do not automatically retry a load after ambiguous COMMIT; its effect may already exist. Report unknown completion explicitly. The harness deletes only its own disposable cluster. Re-running direct loads is not promised idempotent: use a fresh test database or an explicitly idempotent fixture.


## Interfaces and Dependencies

`Hinagata.Postgres.Session.withSession` brackets a Hinagata-owned session opened from `ConnectionTarget`; `Hinagata.Postgres.Load.loadPlan` accepts that session and `FixturePlan`, returning `Either LoadError LoadReport`. A helper `loadInto` brackets one session for one call. Session callbacks may return arbitrary caller values, but no native connection value. `Internal.Libpq` owns all protocol/lifetime code, SQL parameter execution for catalog queries, and identifier quoting; the lifecycle plan reuses it instead of writing another driver. Test support owns disposable PostgreSQL startup only. Add the new package to `cabal.project`, Nix outputs, and `just check` without weakening core gates.

Before completion, distill durable discoveries into the cited local ADRs. Commit on the current branch with a Conventional Commit subject and `MasterPlan: docs/masterplans/1-build-hinagata-for-fast-postgresql-fixtures-and-isolated-microservice-tests.md`, `ExecPlan: docs/plans/2-load-sql-fixtures-atomically-into-existing-postgresql-databases.md`, and `Intention: intention_01m3g1rc9re2qa1cy17q25qfq8` trailers. Record implementation provenance through the installed script using the executing model's verified runtime identity.
