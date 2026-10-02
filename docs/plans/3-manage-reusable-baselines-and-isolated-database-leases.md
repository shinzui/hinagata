---
id: 3
slug: manage-reusable-baselines-and-isolated-database-leases
title: "Manage reusable baselines and isolated database leases"
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
      at: 2026-09-27T00:02:36Z
      mode: "update"
      note: "Clarify cluster-local snapshots and reusable bulk baseline variants."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T00:16:30Z
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
      note: "Shared-mode allocation lock, admin-owned databases with pre-migration grant preparation, orphaned-lease classification, advisory key namespace, clone strategy"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-10-02T06:31:55Z
      mode: "implement"
      note: "Begin versioned maintenance catalog and positive ownership implementation"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T00:27:54Z
      verdict: "changes-requested"
      note: "Allocation lock must be shared not exclusive; apply owner grants before migration hook on PG15+; define orphaned lease recovery; fix advisory key namespace"
---

# Manage reusable baselines and isolated database leases

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update relevant ADRs when durable decisions change.


## Purpose / Big Picture

A test harness can prepare one verified baseline on its existing PostgreSQL cluster and quickly acquire independent databases for repeated or concurrent tests. Leases clean up reliably, can be deliberately retained for debugging, and never delete caller-owned databases. A crash leaves recoverable ownership records.


## Progress

- [ ] Versioned maintenance records and generation publication make baseline reuse/invalidation observable.
- [ ] Concurrent leases receive isolated committed fixture state and release after callback termination.
- [ ] Crash, preservation, detached lease, and cleanup tests prove positive ownership and race safety.

2026-10-02 implementation note: The first milestone is underway. Version-1 DDL lives in `hinagata-postgres/sql/catalog-v1.sql`; `ensureCatalog` initializes a dedicated schema under a transaction and advisory transaction lock, records a cluster UUID, and validates schema/table ownership and format on later opens. `verifyOwnedDatabase` compares name, OID, current owner, and cluster/token comment. `Hinagata.Postgres.Baseline.ensureBaseline` now verifies the frozen plan before allocation, records intent before `CREATE DATABASE`, binds OID and comment before hook work, applies database/schema grants and role-owned settings, runs migration/base-load/verification, checks locale/extensions and open sessions, seals, then publishes. Known revisions reuse only a positively identified ready generation; unknown migration revisions build afresh. The disposable-cluster socket and TCP suites cover separate administration/setup/application roles, a nontransactional `CREATE INDEX CONCURRENTLY` migration, credential rotation, source/revision invalidation, failed rebuild preserving ready state, concurrent cold callers, missing extension, changed marker, and catalog refusal. `just check` passes local package/format/source-distribution/Nix gates, and Haddock generates the exposed PostgreSQL API. Explanation of changed fingerprint components, builder-death/waiter deadlines, clone allocation, leases, and cleanup remain open, so no milestone checkbox is complete yet.

2026-10-02 lease progress: A single-clone `withDatabase` path now compares frozen base/scenario fixture identities before allocation, verifies the complete scenario bundle, and loads only the composed suffix. It takes the generation lock in shared mode, records allocation intent, clones from the sealed baseline using the configured strategy, binds marker/OID, installs a session-held lease lock, and releases the generation lock before callback handoff. Shared grants/settings are reapplied, the application target is handed to the callback, and normal or exceptional return triggers an ownership-checked drop with terminal catalog states. Disposable-cluster tests cover sequential and overlapping warm clones, distinct writable state, exact shared-prefix exclusion, callback exception and failed-load cleanup, and conflicting fixture rejection before allocation. This is a low-level single-clone bracket; manager admission, named collections, result classification, preservation, detached leases, loss-of-session detection, and crash recovery remain open.


## Surprises & Discoveries


## Decision Log

2026-09-26: Use sealed generations and native template cloning on the caller's cluster, rather than dump/restore or in-place reset. Record ownership before nontransactional allocation and refuse ambiguous identities. No migration fingerprint means no persistent cache reuse.

2026-09-30: Architecture review refinements. Clone allocation takes a generation's advisory lock in shared mode so concurrent clones of one template overlap, as PostgreSQL itself permits; build, retirement, and cleanup take it exclusively. The administration role owns every Hinagata-created database and prepares its declared access before the migration hook, because PostgreSQL 15 and later give non-owners no CREATE privilege on `public`. A lease record whose session lock can be acquired is classified orphaned rather than skipped, so crashed leases are recoverable without a time threshold. The clone strategy is a setting with `WAL_LOG` default, not a fingerprint input.

2026-10-02: Apply database/schema grants as the administration database owner, then have setup and application roles apply their own database-specific settings over short-lived connections. PostgreSQL permits ordinary roles to set their own defaults; altering another role would require `CREATEROLE`/admin-option authority unrelated to database ownership. Include role names and setting-value digests in the fingerprint manifest, omitting raw setting values and access passwords.


## Outcomes & Retrospective


## Context and Orientation

Hard dependency: `docs/plans/2-load-sql-fixtures-atomically-into-existing-postgresql-databases.md` supplies the safe native session and loader; its core prerequisite supplies identifiers and bundles. Own `hinagata-postgres/src/Hinagata/Postgres/{Baseline,Lease,Ownership,Cleanup}.hs`, versioned catalog DDL under `hinagata-postgres/sql/`, and lifecycle integration tests. An advisory lock is a PostgreSQL session-held coordination lock released when the connection ends. A lease holds such a lock while a callback actively uses its database.

[ADR 3](../adr/3-sealed-baselines-and-positive-database-ownership.md) owns the cache/deletion boundary; [ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md) reserves migration and schema ownership to applications. `mori://shinzui/keiro/okf/adrs/concepts/ADR-9` means a ledger check is not a schema check. PostgreSQL templates require no connected sessions; database grants/settings need reapplication.

All paths below are repository-relative and proposed unless explicitly described as existing. At planning time only `docs/initial-spec.md`, project metadata, and planning tools existed. The specification now describes the intended library. Dependency research is in `docs/research/initial-design.md`; discover dependency source with Mori before using APIs, then verify current releases with package registries and upstream tags before selecting bounds. Never search the filesystem root or `/nix/store`.

Follow GHC >=9.12, GHC2024, strict unprefixed records, explicit deriving strategies, postpositive qualified imports, and the project prelude. Keep generic-lens orphan imports out of public type-definition modules and the prelude. These conventions come from `mori://shinzui/haskell-jitsurei/docs/core-standards`, `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`.

Every library, executable, test, and benchmark component imports its package's `common common` baseline with GHC2024 and DeriveAnyClass/DuplicateRecordFields/OverloadedLabels/OverloadedStrings. Use generic-lens labels consistently for record access/updates; construction and constructor-directed patterns are valid. Import `Data.Generics.Labels ()` plainly only where required, and inspect transitive imports so public facades do not leak the orphan. Keep entity IDs first in command/event payloads where applicable. Operators stay unqualified; hide clashing prelude exports.

Use MultilineStrings for suitable embedded multiline text per `mori://shinzui/haskell-jitsurei/docs/core-multiline-strings`, preserving external fixture bytes. The [standards audit](../research/haskell-standards-audit.md) records applicability and acceptance ownership. Expected errors are typed; resource cleanup must run on asynchronous exceptions without swallowing them.


## Plan of Work

### Milestone 1: Publish only complete baselines

Create an explicitly configured Hinagata maintenance schema in a caller-selected maintenance database, guarded by project identity and a schema-format version. Never assume permission to modify arbitrary schemas. Store a cluster UUID, project records, immutable baseline generations, allocation operations, and leases. A database record includes generated name, OID, random ownership token, lifecycle state, timestamps, and baseline/run identity. Put the same ownership token in a database catalog comment and compare it with the maintenance record; markers are accident-prevention evidence within a trusted test cluster, not defense against a database superuser.

Use a session advisory lock per project/fingerprint for build decisions. Derive every advisory lock key with the two-argument `pg_advisory_lock(classid, objid)` form: one fixed Hinagata class identifier plus a stable hash of the project/fingerprint, generation, or lease identity. A hash collision only serializes unrelated work, because every decision is rechecked against catalog rows under the lock, and the fixed class keeps Hinagata's keys apart from advisory locks the application may take in the same maintenance database. Record allocation intent, CREATE DATABASE outside a transaction, then capture OID/marker and record ownership. The administration role issues every CREATE DATABASE and therefore owns every Hinagata-created database; that ownership is what lets it clone, comment on, alter, and drop those databases without superuser rights, so never pass a different OWNER. Read the marker back through `pg_shdescription` joined to `pg_database` from the maintenance connection; verifying identity never requires a connection to the clone. If the process dies before identity is bound, leave an ambiguous allocation requiring inspection; never auto-drop an identically named unknown database. Before the migration hook runs, prepare the fresh generation: the administration role applies database and schema grants, then each setup/application role applies its own declared database-specific settings through a short-lived connection. PostgreSQL 15 and later give no CREATE privilege on the `public` schema to roles other than the database owner. Then apply migrations through `MigrationHook`, then load base `FixturePlan`, then run `VerificationHook`. Both hooks receive the new target, return typed outcomes, and must release all connections before return. Close setup sessions, set ALLOW_CONNECTIONS false, and only then publish Ready metadata in a transaction. Keep the previous ready generation on failure.

Treat each sealed generation as a cluster-local snapshot. Allow multiple baseline specifications per project, so a large repeatedly used scenario closure can be loaded once into its own baseline and then cloned without reloading those rows. Do not imply zero-copy or constant-time cloning, and do not add portable dump/restore in this initiative.

Fingerprint versioned migration revision, base-bundle digest, explicit schema-affecting settings, PostgreSQL major, and locale/extension requirements. Verify observed requirements before publication. Unknown migration inputs select a fresh generation instead of reusable Ready lookup. On reuse, validate cluster/catalog/database/marker identity and sealed state. Rebuild on input changes; preserve existing issued clones. An owner-supplied verification hook controls live-schema checks rather than Hinagata inspecting another library's private schema.

Persist a versioned non-secret fingerprint manifest with role/ownership requirements, declared grants/settings, and revisions for state-affecting hooks. Unknown hook revisions also disable persistent reuse. Passwords and password-derived hashes never participate. Return structured reuse/build reasons and changed component categories against an explicitly selected previous generation; report no comparison when none exists. Test migration, fixture, role, and hook changes independently, plus credential rotation without a schema rebuild.

Represent Building, Ready, Failed, and Retiring generation states separately from lease states. Waiters use one acquisition deadline, observe terminal build outcomes, and can cancel without cancelling another caller's builder. A later explicit attempt may retry a failed build. Test builder failure, builder process death, waiter cancellation, and deadline expiry; no incomplete generation is acquired and no waiter hangs. Keep coordination locks in the maintenance database and leave migration-hook transaction boundaries to the migration tool; include a migration with CREATE INDEX CONCURRENTLY.

### Milestone 2: Bracketed clones and named collections

Acquire a baseline generation by taking its advisory lock in shared mode (`pg_advisory_lock_shared`), allocate a unique clone from a maintenance connection, and record identity before handoff. Shared mode matters: PostgreSQL takes only a share lock on the template during CREATE DATABASE, so several clones of one baseline may be created concurrently, and Hinagata must not serialize them with an exclusive lock of its own. Retirement and cleanup of that generation take the same lock exclusively and therefore wait for in-flight allocations. Pass the configured clone strategy to CREATE DATABASE (`WAL_LOG` by default; `FILE_COPY` only when a measurement justifies it for a large baseline); the strategy is not a fingerprint input. Set connections allowed explicitly for the clone. Reapply the same declared database-level settings/grants used for the generation, invoke an optional trusted clone preparation hook, and load scenario fixtures transactionally under setup access. Resolve base plus scenario plans through the core composition operation before allocation; execute only the suffix beyond the exact verified base prefix. Never skip by fixture name alone. Handoff carries the application endpoint, while administration credentials remain private. Test that a shared reference fixture is present once, mismatched captured definitions are rejected without allocation, and the application role can perform its required work while a forbidden administrative operation fails. Then call the consumer with `LeaseInfo` containing a secret-safe endpoint and run/lease IDs. Keep the maintenance lock/session alive until consumers have returned and shut down pools/processes. Detect loss of the ownership connection and fail the lease scope; do not continue as if exclusivity remains valid.

The outer callback's return is the shutdown boundary; no lease may be dropped while its callback is still running. Normal success releases; a caller-provided result classifier identifies failures returned as values, and both classified and thrown failure obey the explicit preservation policy. Return the original callback value unchanged with cleanup diagnostics kept distinct. Cancellation is handled separately. Tests cover successful values, failure values, synchronous exceptions, cancellation, and cleanup failure; add a test-framework adapter example without coupling the core to that framework. Cancellation runs bounded cleanup and rethrows. Avoid losing the primary exception to a DROP failure. Define a `withDatabases` operation over a named non-empty set of requests, acquiring in stable order and unwinding successful earlier allocations if a later one fails. This supports independent service databases without promising distributed atomicity.

Use a bracketed suite-scoped manager with configured setup-worker, active-lease, and pending-request limits. Bound the queue itself; reject saturation explicitly, allow cancellation, and spend one acquisition deadline across queueing, locks, and setup. Reserve capacity for an entire named collection before allocation, refusing requests larger than the limit, so partial collections cannot deadlock one another. Do not hold database sessions merely to wait in the local queue. Document manager-local limits and the caller's budget for multiple managers/processes and application pools; this is not global cluster admission control. Retained/detached database storage outlives active callback capacity and must remain visible in inspection. Account for maintenance lock connections and bounded cleanup headroom. Test saturation, cancellation, capacity release, collection admission, and measured maximum connections.

Retain `FixturePlan` and `BaselineRef` across the manager scope without recompiling source files on each lease. Revalidate baseline identity/sealed state for every acquisition. Report queue wait, lock wait, build/reuse, clone, scenario load, and release timings. Do not add a ready-clone pool to this plan; the performance plan may investigate it under the [prior-art review](../research/prior-art.md).

Baseline retirement takes the generation's lock exclusively and checks outstanding acquisition/reference records under the same lock protocol. Existing clones do not need a live template after successful creation, but active acquisition does. Test concurrent cold builders publish one reusable result and concurrent warm callers have disjoint writable databases.

### Milestone 3: Ownership-aware recovery

Define explicit states: Allocating, Loading, Active, Detached, Preserved, Releasing, Released, and CleanupFailed. Record state transitions before/after nontransactional operations. Detached acquisition is deliberately retained and released by ID, not considered abandoned solely because the acquiring process exits. Active callbacks own a session lock; cleanup must try to acquire it without waiting and recheck state/identity. A lease whose lock is held is live and is always skipped. An Active, Allocating, Loading, or Releasing record whose lock can be acquired has lost its owning session, which is the only evidence of a crash Hinagata accepts: report it as orphaned, and remove it only under explicit apply after positive identity checks. Detached, preserved, protected, and ambiguous records are skipped unless explicit selection permits retained resources. A time threshold alone never proves abandonment.

Implement `planCleanup` as a read-only candidate report and `applyCleanup` as revalidated operations under locks. An old preview is not deletion authority. Support idempotent release of an already absent matching allocation; name/OID/token mismatches refuse. Use FORCE only for positively owned clones after the callback/process scope ended. Surface permissions, prepared transactions, or replication-related drop refusal and retain records. Do not drop cluster roles, databases, or services owned by the bootstrap.

Fault-inject after intent, CREATE, marker binding, load, seal, publication, handoff, and DROP. Prove both compensation and conservative ambiguous recovery. Document catalog-format compatibility: refuse unknown versions and perform explicit transactional additive upgrades, not silent schema replacement.


## Concrete Steps

Run from the Hinagata repository root. The commands below are acceptance interfaces to create in this plan or consume from its prerequisites; they are not claimed to work in the original documentation-only tree.

```bash
nix develop -c cabal build hinagata-postgres
nix develop -c just test-postgres
nix develop -c just check
```

Instrument migrations: repeated identical requests run them once; changing migration revision or a base CSV byte builds a new baseline. A failed rebuild leaves the earlier baseline usable. A million-row prepared baseline variant is loaded once, and repeated clones contain those rows without re-executing COPY; changed source bytes select a new generation. Eight concurrent warm callers get distinct databases, their CREATE DATABASE calls overlap in time rather than queueing on Hinagata's lock, and they cannot see one another's inserts. A live lease survives concurrent cleanup. A preserved/detached lease survives ordinary cleanup and releases only by explicit selection. A same-prefix foreign database, altered OID/token, protected maintenance target, or replaced cluster is refused. Kill a worker at each allocation boundary; subsequent cleanup never removes an unproven target, while a lease whose owning session died is reported as orphaned and removed only on explicit apply. Verify generation and clone grants/settings, including a setup role distinct from the administration role creating tables in `public` on a fresh generation, missing CREATEDB permission diagnostics, and socket operation throughout.


## Validation and Acceptance

Acceptance requires the observable results above, passing focused tests, and the repository checks appropriate to the completed components. Record concise evidence here and in Progress; do not report planned commands as executed. Build documentation from the exposed library API and keep examples runnable. Update dependency metadata and check source distributions when adding a package or public module.


## Idempotence and Recovery

Build new generations without modifying ready ones. Retry a failed load on a newly acquired clone, not a partially trusted one. Allocation intent makes crashes inspectable; manual ownership repair must require a concrete explicit target and evidence. Dropping an owned missing database is idempotent, but a matching name with a different identity is not. Do not repair borrowed databases or terminate their sessions.


## Interfaces and Dependencies

`BaselineSpec` contains migration revision, base plan, server requirements, migration/verification hooks, the declared database-level grants and settings applied to both generations and clones, the clone strategy, and the optional clone preparation hook. `withManager` brackets bounded admission/resources; `ensureBaseline` returns an opaque `BaselineRef` plus a structured preparation report; `withDatabase` consumes a manager, brackets a request and `LeaseInfo` callback, and accepts an explicit callback-result classifier; `withDatabases` returns a named collection. `acquireDetached`, `releaseLease`, `preserveLease`, `inspectLease`, `planCleanup`, and `applyCleanup` share the same state machine and catalog. The maintenance schema and all ownership transitions have this plan as sole owner. The CLI consumes these operations without direct catalog SQL. Native driver primitives remain owned by `Hinagata.Postgres.Internal.Libpq`; extend that adapter rather than bypassing it.

Before completion, distill durable discoveries into the cited local ADRs. Commit on the current branch with a Conventional Commit subject and `MasterPlan: docs/masterplans/1-build-hinagata-for-fast-postgresql-fixtures-and-isolated-microservice-tests.md`, `ExecPlan: docs/plans/3-manage-reusable-baselines-and-isolated-database-leases.md`, and `Intention: intention_01m3g1rc9re2qa1cy17q25qfq8` trailers. Record implementation provenance through the installed script using the executing model's verified runtime identity.
