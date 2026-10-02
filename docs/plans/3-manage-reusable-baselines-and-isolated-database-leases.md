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

- [x] Versioned maintenance records and generation publication make baseline reuse/invalidation observable.
- [x] Concurrent leases receive isolated committed fixture state and release after callback termination.
- [ ] Crash, preservation, detached lease, and cleanup tests prove positive ownership and race safety.

2026-10-02 implementation note: The first milestone is underway. Version-1 DDL lives in `hinagata-postgres/sql/catalog-v1.sql`; `ensureCatalog` initializes a dedicated schema under a transaction and advisory transaction lock, records a cluster UUID, and validates schema/table ownership and format on later opens. `verifyOwnedDatabase` compares name, OID, current owner, and cluster/token comment. `Hinagata.Postgres.Baseline.ensureBaseline` now verifies the frozen plan before allocation, records intent before `CREATE DATABASE`, binds OID and comment before hook work, applies database/schema grants and role-owned settings, runs migration/base-load/verification, checks locale/extensions and open sessions, seals, then publishes. Known revisions reuse only a positively identified ready generation; unknown migration revisions build afresh. The disposable-cluster socket and TCP suites cover separate administration/setup/application roles, a nontransactional `CREATE INDEX CONCURRENTLY` migration, credential rotation, source/revision invalidation, failed rebuild preserving ready state, concurrent cold callers, missing extension, changed marker, and catalog refusal. `just check` passes local package/format/source-distribution/Nix gates, and Haddock generates the exposed PostgreSQL API. Explanation of changed fingerprint components, builder-death/waiter deadlines, clone allocation, leases, and cleanup remain open, so no milestone checkbox is complete yet.

2026-10-02 lease progress: A single-clone `withDatabase` path now compares frozen base/scenario fixture identities before allocation, verifies the complete scenario bundle, and loads only the composed suffix. It takes the generation lock in shared mode, records allocation intent, clones from the sealed baseline using the configured strategy, binds marker/OID, installs a session-held lease lock, and releases the generation lock before callback handoff. Shared grants/settings are reapplied, the application target is handed to the callback, and normal or exceptional return triggers an ownership-checked drop with terminal catalog states. Disposable-cluster tests cover sequential and overlapping warm clones, distinct writable state, exact shared-prefix exclusion, callback exception and failed-load cleanup, and conflicting fixture rejection before allocation. This is the low-level single-clone bracket used by the manager below.

2026-10-02 manager progress: `withManager` now brackets local active-lease and setup-worker gates. Active acquisition has a bounded pending queue with cancellation-safe capacity release; `withManagedDatabase` releases its setup worker at callback handoff. `withDatabases` validates nonempty unique names, reserves the entire collection capacity before allocation, acquires in stable name order, and unwinds earlier clones after a later failure. Integration tests cover a successful named collection, later-lease failure, oversized refusal, queue saturation, queued cancellation, deadline expiry without cancelling another lease, and capacity release. One monotonic deadline covers active and setup queueing and passes the remaining budget to the clone path; end-to-end allocation/setup deadline enforcement, measured connection ceilings, callback-result classification, preservation and detached states, and recovery remain open.

2026-10-02 cleanup progress: `inspectCatalog` validates an existing maintenance schema without creating it, so `planCleanup` is read-only apart from transient liveness try-locks. The preview pages project allocations and classifies live, orphaned, retained, missing, foreign, and ambiguous records. `applyCleanup` requires selected allocation IDs; for each it takes the generation lock exclusively, re-reads the allocation, tries its lease lock, protects maintenance/template targets, and rechecks name/OID/owner/marker before force-dropping a clone. State updates for allocation and lease use one SQL statement, and an absent positively bound clone is idempotently marked Released. Disposable-cluster tests cover orphan preview/apply, a live callback, retained selection, altered marker, unbound identity, protected maintenance target, and idempotence. Process-death boundary tests, detached acquisition/release, explicit preservation policy, and recovery diagnostics remain open.

2026-10-02 retention progress: `withDatabaseClassified` accepts an explicit callback-result classifier and retention policy, returns the callback value unchanged in `LeaseOutcome`, and reports release/retention plus cleanup diagnostics separately. `PreserveFailures` records returned and thrown failures as Preserved, while `ReleaseAlways` keeps the simple bracket behavior. `acquireDetached` records a ready clone as Detached; `releaseLease` resolves its public lease ID and repeats ownership-checked cleanup. Managed classified/detached paths honor active and setup admission. Integration tests cover success-value release, failure-value preservation, exception preservation and rethrow, detached acquisition, explicit release, and managed capacity release. Process-death boundary tests, complete operation deadlines, measured connection ceilings, preparation explanations, and full recovery diagnostics remain open.

2026-10-02 cancellation progress: Asynchronous callback cancellation now attempts clone release even under `PreserveFailures`, then rethrows the original asynchronous exception. The disposable-cluster test kills a callback after handoff and verifies both its Released catalog state and absent database. Cancellation during pre-handoff allocation may still leave a catalog-recorded orphan for explicit recovery; cross-phase acquisition deadlines remain open.

2026-10-02 fingerprint progress: `BaselineSpec.compareAgainst` accepts an explicitly selected prior `BaselineRef`. The preparation report then reads that generation's versioned non-secret manifest and returns changed component categories; without a selected prior generation it reports no comparison. The socket integration test checks separate migration, base-fixture, verification-hook, and application-setting changes, plus credential rotation yielding an empty change list. Builder-death and waiter deadline proof are still open, so the first milestone remains incomplete.

2026-10-02 acquisition progress: A monotonic lease acquisition deadline now spans bundle verification, catalog setup, maintenance connection establishment, clone allocation, and scenario loading. Managed acquisition passes its remaining queue/setup budget into the same path. A timed-out scenario load attempts ownership-checked release before returning, while the consumer callback is outside the acquisition deadline; socket and TCP tests cover both behaviors. Allocation interrupted before the clone identity is returned remains a catalog-recorded recovery case. Baseline builder/waiter deadline proof remains open.

2026-10-02 generation recovery progress: Once the project/fingerprint builder lock is acquired, the next caller marks any interrupted Building records for that fingerprint Failed before ready lookup or retry. A disposable-cluster test stops a builder during its migration hook, cancels one waiting caller, lets another waiting caller's deadline expire, then verifies that a surviving waiter publishes one Ready generation and the interrupted generation remains inspectable as Failed. This completes the first progress milestone; allocation-boundary and catalog-upgrade recovery proof remain in the third.

2026-10-02 lease inspection progress: `inspectLease` looks up a public lease ID and classifies live, retained, missing, foreign, and released records without changing them. `preserveLease` uses the same generation lock, live lease try-lock, protected-target checks, and name/OID/owner/marker verification as cleanup before atomically marking an ended clone Preserved. Integration tests cover live refusal, detached preservation, foreign-marker refusal, idempotent preservation, and inspection after release. Allocation-boundary process kills and catalog-format upgrades remain open in the third milestone.

2026-10-02 clone preparation progress: `BaselineSpec.clonePreparationHook` travels in the opaque in-memory `BaselineRef` and runs with setup access after clone grants/settings but before transactional scenario loading. It does not change the sealed template or its fingerprint; reused baseline handles use the hook supplied by the current request. A disposable-cluster test verifies the hook prepares a table in each of two clones before application callback handoff, and a failed hook prevents handoff and releases its clone. Clone/release timing reports and measured connection ceilings remain open in the second milestone.

2026-10-02 retirement progress: `retireBaseline` takes the generation lock exclusively, rechecks the project/catalog row and positive database identity, marks the sealed template Retiring, then drops it. The Retiring row remains as a tombstone because existing clone allocations reference that generation. Retrying after a successful drop is idempotent; a stale baseline handle cannot allocate, and a later ensure call may build a new Ready generation for the same fingerprint. Socket integration covers these boundaries. The integration test module was split into smaller lifecycle functions and its test-suite component compiles with `-O0`; library and benchmark optimization settings are unchanged.

2026-10-02 connection evidence: The disposable-cluster socket and TCP suites hold four managed callbacks open with one application session apiece and observe nine client connections total: four maintenance lock sessions, four application sessions, and the observing administration session. This measures the local manager ceiling in that setup, not a global cluster admission guarantee. Detailed queue/lock/clone/load/release timing reports remain open in the second milestone.

2026-10-02 catalog upgrade progress: New catalogs use format 2 with nullable generation/allocation failure diagnostics. `ensureCatalog` upgrades an owned format-1 schema under the existing bootstrap transaction and advisory lock, preserving its UUID and records; `inspectCatalog` asks the caller to perform the upgrade while remaining read-only. Disposable-cluster socket and TCP tests create a real format-1 schema, verify refusal before upgrade, then verify format-2 identity and columns afterward. A deliberately failing second upgrade statement proves that the first DDL change rolls back and the catalog remains at format 1. Failed generation builds, interrupted builders, and failed clone drops now retain generic diagnostics. Allocation-boundary process kills remain in the third milestone.

2026-10-02 lost-session evidence: A disposable-cluster test terminates the maintenance backend holding a handed-off lease lock. Callback completion reports failure instead of claiming release; the allocation remains inspectable as an orphan and requires explicit ownership-checked apply. This covers detection at completion, not immediate interruption of a still-running callback. Process-kill tests at allocation boundaries and loss detection during callback execution remain open.

2026-10-02 lifecycle timing progress: `LeaseOutcome` now includes `LeaseTimings` with separate monotonic durations for manager queue admission, catalog setup, generation-lock wait, clone creation/binding, scenario connection/load, and lease completion. Direct leases report zero queue time; the manager sums active and setup gate waits. Integration tests use a two-second scenario and a deliberately queued managed request to verify the stage attribution. `PreparationReport` already pairs build/reuse kind with its elapsed duration. Timing for failures before handoff and named collections is still open.

2026-10-02 process-crash progress: The disposable-cluster test executable now spawns a separate worker and kills it with SIGKILL after a baseline reaches its migration hook, while a clone is Loading, and after callback handoff. The surviving baseline caller marks the interrupted Building generation Failed and publishes one Ready generation. A killed Loading or Active clone becomes an inspectable orphan; only explicit `applyCleanup` removes its positively owned database. Fault injection at marker binding, seal, publication, and DROP remains open, as does proving behavior when the maintenance connection dies while a callback continues running.

2026-10-02 unbound-allocation progress: Disposable-cluster socket and TCP tests kill a worker with a committed Allocating record while `CREATE DATABASE` is blocked, and after `CREATE DATABASE` completes while `COMMENT ON DATABASE` is blocked. Both records remain Ambiguous after the worker and its server backend exit. Explicit orphan cleanup refuses the unbound identity and does not delete a database; the second case verifies the newly created database remains. Marker binding, seal, publication, and DROP process-kill boundaries remain open.

2026-10-02 drop-failure progress: The disposable PostgreSQL test cluster enables prepared transactions solely for fault injection. A prepared transaction in a detached clone makes `releaseLease` fail at `DROP DATABASE ... WITH (FORCE)`; the clone remains present and its allocation and lease become CleanupFailed with a stored diagnostic. Rolling back the prepared transaction permits an explicit release retry. The socket and TCP suites and `just check` pass.

2026-10-02 callback cleanup progress: Ordinary callback completion now records the bounded DROP failure reason in the allocation alongside CleanupFailed, and a successful retry clears that stale diagnostic. A prepared transaction created during the callback forces this path; the callback value still returns with a separate cleanup diagnostic, while an explicit retry after `ROLLBACK PREPARED` releases the clone. The disposable-cluster socket and TCP suites and `just check` pass.

2026-10-02 warm-concurrency progress: Eight simultaneous direct lease callers now reach their callbacks with eight distinct writable databases while the observer holds a compatible shared generation lock. All eight release cleanly. This proves Hinagata does not require an exclusive generation lock for warm allocation; a measured overlap of the PostgreSQL CREATE DATABASE statements themselves remains open.


## Surprises & Discoveries

2026-10-02: Killing a client blocked during `CREATE DATABASE` does not prove the server canceled the statement. Releasing the blocking catalog lock let that backend complete the CREATE before it exited. The fault test waits for backend termination before comparing database existence; recovery continues to treat the unbound allocation as ambiguous even when the intended name now exists.


## Decision Log

2026-09-26: Use sealed generations and native template cloning on the caller's cluster, rather than dump/restore or in-place reset. Record ownership before nontransactional allocation and refuse ambiguous identities. No migration fingerprint means no persistent cache reuse.

2026-09-30: Architecture review refinements. Clone allocation takes a generation's advisory lock in shared mode so concurrent clones of one template overlap, as PostgreSQL itself permits; build, retirement, and cleanup take it exclusively. The administration role owns every Hinagata-created database and prepares its declared access before the migration hook, because PostgreSQL 15 and later give non-owners no CREATE privilege on `public`. A lease record whose session lock can be acquired is classified orphaned rather than skipped, so crashed leases are recoverable without a time threshold. The clone strategy is a setting with `WAL_LOG` default, not a fingerprint input.

2026-10-02: Apply database/schema grants as the administration database owner, then have setup and application roles apply their own database-specific settings over short-lived connections. PostgreSQL permits ordinary roles to set their own defaults; altering another role would require `CREATEROLE`/admin-option authority unrelated to database ownership. Include role names and setting-value digests in the fingerprint manifest, omitting raw setting values and access passwords.

2026-10-02: Compare fingerprints only against a caller-selected prior generation. A new baseline has no meaningful implicit predecessor when projects can have several baseline variants; an absent selection is reported as no comparison, not as an inferred change.

2026-10-02: Mark interrupted Building records Failed only after acquiring their project/fingerprint advisory lock. The lock proves no builder for that fingerprint still owns publication; the existing database and ownership record remain for explicit inspection rather than implicit deletion.


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
