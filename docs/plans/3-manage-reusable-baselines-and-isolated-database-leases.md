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
---

# Manage reusable baselines and isolated database leases

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update relevant ADRs when durable decisions change.


## Purpose / Big Picture

A test harness can prepare one verified baseline on its existing PostgreSQL cluster and quickly acquire independent databases for repeated or concurrent tests. Leases clean up reliably, can be deliberately retained for debugging, and never delete caller-owned databases. A crash leaves recoverable ownership records.


## Progress

- [ ] Versioned maintenance records and generation publication make baseline reuse/invalidation observable.
- [ ] Concurrent leases receive isolated committed fixture state and release after callback termination.
- [ ] Crash, preservation, detached lease, and cleanup tests prove positive ownership and race safety.


## Surprises & Discoveries


## Decision Log

2026-09-26: Use sealed generations and native template cloning on the caller's cluster, rather than dump/restore or in-place reset. Record ownership before nontransactional allocation and refuse ambiguous identities. No migration fingerprint means no persistent cache reuse.


## Outcomes & Retrospective


## Context and Orientation

Hard dependency: `docs/plans/2-load-sql-fixtures-atomically-into-existing-postgresql-databases.md` supplies the safe native session and loader; its core prerequisite supplies identifiers and bundles. Own `hinagata-postgres/src/Hinagata/Postgres/{Baseline,Lease,Ownership,Cleanup}.hs`, versioned catalog DDL under `hinagata-postgres/sql/`, and lifecycle integration tests. An advisory lock is a PostgreSQL session-held coordination lock released when the connection ends. A lease holds such a lock while a callback actively uses its database.

[ADR 3](../adr/3-sealed-baselines-and-positive-database-ownership.md) owns the cache/deletion boundary; [ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md) reserves migration and schema ownership to applications. `mori://shinzui/keiro/okf/adrs/concepts/ADR-9` means a ledger check is not a schema check. PostgreSQL templates require no connected sessions; database grants/settings need reapplication.

All paths below are repository-relative and proposed unless explicitly described as existing. At planning time only `docs/initial-spec.md`, project metadata, and planning tools existed. The specification now describes the intended library. Dependency research is in `docs/research/initial-design.md`; discover dependency source with Mori before using APIs, then verify current releases with package registries and upstream tags before selecting bounds. Never search the filesystem root or `/nix/store`.

Follow GHC >=9.12, GHC2024, strict unprefixed records, explicit deriving strategies, postpositive qualified imports, and the project prelude. Keep generic-lens orphan imports out of public type-definition modules and the prelude. These conventions come from `mori://shinzui/haskell-jitsurei/docs/core-standards`, `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`. Expected errors are typed; resource cleanup must run on asynchronous exceptions without swallowing them.


## Plan of Work

### Milestone 1: Publish only complete baselines

Create an explicitly configured Hinagata maintenance schema in a caller-selected maintenance database, guarded by project identity and a schema-format version. Never assume permission to modify arbitrary schemas. Store a cluster UUID, project records, immutable baseline generations, allocation operations, and leases. A database record includes generated name, OID, random ownership token, lifecycle state, timestamps, and baseline/run identity. Put the same ownership token in a database catalog comment and compare it with the maintenance record; markers are accident-prevention evidence within a trusted test cluster, not defense against a database superuser.

Use a session advisory lock per project/fingerprint for build decisions. Record allocation intent, CREATE DATABASE outside a transaction, then capture OID/marker and record ownership. If the process dies before identity is bound, leave an ambiguous allocation requiring inspection; never auto-drop an identically named unknown database. Apply migrations through `MigrationHook`, then load base `FixturePlan`, then run `VerificationHook`. Both hooks receive the new target, return typed outcomes, and must release all connections before return. Close setup sessions, set ALLOW_CONNECTIONS false, and only then publish Ready metadata in a transaction. Keep the previous ready generation on failure.

Treat each sealed generation as a cluster-local snapshot. Allow multiple baseline specifications per project, so a large repeatedly used scenario closure can be loaded once into its own baseline and then cloned without reloading those rows. Do not imply zero-copy or constant-time cloning, and do not add portable dump/restore in this initiative.

Fingerprint versioned migration revision, base-bundle digest, explicit schema-affecting settings, PostgreSQL major, and locale/extension requirements. Verify observed requirements before publication. Unknown migration inputs select a fresh generation instead of reusable Ready lookup. On reuse, validate cluster/catalog/database/marker identity and sealed state. Rebuild on input changes; preserve existing issued clones. An owner-supplied verification hook controls live-schema checks rather than Hinagata inspecting another library's private schema.

Persist a versioned non-secret fingerprint manifest with role/ownership requirements, declared grants/settings, and revisions for state-affecting hooks. Unknown hook revisions also disable persistent reuse. Passwords and password-derived hashes never participate. Return structured reuse/build reasons and changed component categories against an explicitly selected previous generation; report no comparison when none exists. Test migration, fixture, role, and hook changes independently, plus credential rotation without a schema rebuild.

Represent Building, Ready, Failed, and Retiring generation states separately from lease states. Waiters use one acquisition deadline, observe terminal build outcomes, and can cancel without cancelling another caller's builder. A later explicit attempt may retry a failed build. Test builder failure, builder process death, waiter cancellation, and deadline expiry; no incomplete generation is acquired and no waiter hangs. Keep coordination locks in the maintenance database and leave migration-hook transaction boundaries to the migration tool; include a migration with CREATE INDEX CONCURRENTLY.

### Milestone 2: Bracketed clones and named collections

Acquire a baseline generation under the allocation/retirement lock, allocate a unique clone from a maintenance connection, and record identity before handoff. Set connections allowed explicitly for the clone. Reapply declared database-level settings/grants, invoke an optional trusted clone preparation hook, and load scenario fixtures transactionally under setup access. Resolve base plus scenario plans through the core composition operation before allocation; execute only the suffix beyond the exact verified base prefix. Never skip by fixture name alone. Handoff carries the application endpoint, while administration credentials remain private. Test that a shared reference fixture is present once, mismatched captured definitions are rejected without allocation, and the application role can perform its required work while a forbidden administrative operation fails. Then call the consumer with `LeaseInfo` containing a secret-safe endpoint and run/lease IDs. Keep the maintenance lock/session alive until consumers have returned and shut down pools/processes. Detect loss of the ownership connection and fail the lease scope; do not continue as if exclusivity remains valid.

The outer callback's return is the shutdown boundary; no lease may be dropped while its callback is still running. Normal success releases; a caller-provided result classifier identifies failures returned as values, and both classified and thrown failure obey the explicit preservation policy. Return the original callback value unchanged with cleanup diagnostics kept distinct. Cancellation is handled separately. Tests cover successful values, failure values, synchronous exceptions, cancellation, and cleanup failure; add a test-framework adapter example without coupling the core to that framework. Cancellation runs bounded cleanup and rethrows. Avoid losing the primary exception to a DROP failure. Define a `withDatabases` operation over a named non-empty set of requests, acquiring in stable order and unwinding successful earlier allocations if a later one fails. This supports independent service databases without promising distributed atomicity.

Use a bracketed suite-scoped manager with configured setup-worker, active-lease, and pending-request limits. Bound the queue itself; reject saturation explicitly, allow cancellation, and spend one acquisition deadline across queueing, locks, and setup. Reserve capacity for an entire named collection before allocation, refusing requests larger than the limit, so partial collections cannot deadlock one another. Do not hold database sessions merely to wait in the local queue. Document manager-local limits and the caller's budget for multiple managers/processes and application pools; this is not global cluster admission control. Retained/detached database storage outlives active callback capacity and must remain visible in inspection. Account for maintenance lock connections and bounded cleanup headroom. Test saturation, cancellation, capacity release, collection admission, and measured maximum connections.

Retain `FixturePlan` and `BaselineRef` across the manager scope without recompiling source files on each lease. Revalidate baseline identity/sealed state for every acquisition. Report queue wait, lock wait, build/reuse, clone, scenario load, and release timings. Do not add a ready-clone pool to this plan; the performance plan may investigate it under the [prior-art review](../research/prior-art.md).

Baseline retirement checks outstanding acquisition/reference records under the same lock protocol. Existing clones do not need a live template after successful creation, but active acquisition does. Test concurrent cold builders publish one reusable result and concurrent warm callers have disjoint writable databases.

### Milestone 3: Ownership-aware recovery

Define explicit states: Allocating, Loading, Active, Detached, Preserved, Releasing, Released, and CleanupFailed. Record state transitions before/after nontransactional operations. Detached acquisition is deliberately retained and released by ID, not considered abandoned solely because the acquiring process exits. Active callbacks own a session lock; cleanup must acquire it, recheck state/identity, and skip anything active, detached, preserved, protected, or ambiguous unless explicit selection permits retained resources. A time threshold alone never proves abandonment.

Implement `planCleanup` as a read-only candidate report and `applyCleanup` as revalidated operations under locks. An old preview is not deletion authority. Support idempotent release of an already absent matching allocation; name/OID/token mismatches refuse. Use FORCE only for positively owned clones after the callback/process scope ended. Surface permissions, prepared transactions, or replication-related drop refusal and retain records. Do not drop cluster roles, databases, or services owned by the bootstrap.

Fault-inject after intent, CREATE, marker binding, load, seal, publication, handoff, and DROP. Prove both compensation and conservative ambiguous recovery. Document catalog-format compatibility: refuse unknown versions and perform explicit transactional additive upgrades, not silent schema replacement.


## Concrete Steps

Run from the Hinagata repository root. The commands below are acceptance interfaces to create in this plan or consume from its prerequisites; they are not claimed to work in the original documentation-only tree.

```bash
nix develop -c cabal build hinagata-postgres
nix develop -c just test-postgres
nix develop -c just check
```

Instrument migrations: repeated identical requests run them once; changing migration revision or a base CSV byte builds a new baseline. A failed rebuild leaves the earlier baseline usable. A million-row prepared baseline variant is loaded once, and repeated clones contain those rows without re-executing COPY; changed source bytes select a new generation. Eight concurrent callers get distinct databases and cannot see one another's inserts. A live lease survives concurrent cleanup. A preserved/detached lease survives ordinary cleanup and releases only by explicit selection. A same-prefix foreign database, altered OID/token, protected maintenance target, or replaced cluster is refused. Kill a worker at each allocation boundary; subsequent cleanup never removes an unproven target. Verify cloned grants/settings, missing CREATEDB permission diagnostics, and socket operation throughout.


## Validation and Acceptance

Acceptance requires the observable results above, passing focused tests, and the repository checks appropriate to the completed components. Record concise evidence here and in Progress; do not report planned commands as executed. Build documentation from the exposed library API and keep examples runnable. Update dependency metadata and check source distributions when adding a package or public module.


## Idempotence and Recovery

Build new generations without modifying ready ones. Retry a failed load on a newly acquired clone, not a partially trusted one. Allocation intent makes crashes inspectable; manual ownership repair must require a concrete explicit target and evidence. Dropping an owned missing database is idempotent, but a matching name with a different identity is not. Do not repair borrowed databases or terminate their sessions.


## Interfaces and Dependencies

`BaselineSpec` contains migration revision, base plan, server requirements, migration/verification hooks, and clone settings/preparation. `withManager` brackets bounded admission/resources; `ensureBaseline` returns an opaque `BaselineRef` plus a structured preparation report; `withDatabase` consumes a manager, brackets a request and `LeaseInfo` callback, and accepts an explicit callback-result classifier; `withDatabases` returns a named collection. `acquireDetached`, `releaseLease`, `preserveLease`, `inspectLease`, `planCleanup`, and `applyCleanup` share the same state machine and catalog. The maintenance schema and all ownership transitions have this plan as sole owner. The CLI consumes these operations without direct catalog SQL. Native driver primitives remain owned by `Hinagata.Postgres.Internal.Libpq`; extend that adapter rather than bypassing it.

Before completion, distill durable discoveries into the cited local ADRs. Commit on the current branch with a Conventional Commit subject and `MasterPlan: docs/masterplans/1-build-hinagata-for-fast-postgresql-fixtures-and-isolated-microservice-tests.md`, `ExecPlan: docs/plans/3-manage-reusable-baselines-and-isolated-database-leases.md`, and `Intention: intention_01m3g1rc9re2qa1cy17q25qfq8` trailers. Record implementation provenance through the installed script using the executing model's verified runtime identity.
