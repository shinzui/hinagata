# ADR 3: Sealed baselines and positive database ownership

Status: Accepted

Date: 2026-09-26

Amended: 2026-10-01 (lock modes, generation preparation, explicit schema grants, orphan classification)

Amended: 2026-10-02 (role-owned database settings during generation preparation)

Amended: 2026-10-02 (read-only cleanup inspection and per-ID locked revalidation)

Amended: 2026-10-02 (classified callback outcomes and explicit retained release)

Amended: 2026-10-02 (per-clone preparation before scenario loading)

Amended: 2026-10-02 (ownership-checked sealed baseline retirement)

Amended: 2026-10-02 (transactional catalog v1-to-v2 upgrade and failure diagnostics)

## Context

Reuse must not silently test stale migrations or share scenario state. CREATE/DROP DATABASE are nontransactional, and copying a template requires no connected sessions.

## Decision

Build immutable generations on the existing cluster; migrate, load, verify, disconnect, seal, then publish. Fingerprints cover real migration identity, frozen base sources, configuration, and server requirements. Reuse requires matching cluster/catalog/database identity. A maintenance catalog records allocation intent, identity, baseline/run association, and active/detached/preserved state. Advisory locks coordinate build, acquisition, retirement, and cleanup: a generation's lock is taken in shared mode by clone allocation and exclusively by build, retirement, and cleanup, matching PostgreSQL's own share lock on the template so concurrent clones are never serialized by Hinagata. The administration role owns every database Hinagata creates and applies declared database and schema grants before the application migration hook, and on every clone. Each setup or application role applies its own declared `ALTER ROLE ... IN DATABASE ... SET` values through a short-lived connection, so the database owner does not need `CREATEROLE` over those roles. PostgreSQL 15 and later give non-owners no `CREATE` on `public`; database `CREATE` alone does not confer that schema privilege, so setup roles migrating into `public` need an explicit schema grant.

Store a non-secret fingerprint manifest, including state-affecting role/configuration and hook revisions, with explainable reuse/build outcomes. Reusable handles avoid rereading fixture bytes but do not bypass database identity checks. Baseline/scenario composition resolves base roots first and skips only that verified prefix on a fresh clone; conflicting shared definitions are errors. Concurrent construction has deadline-bound cancellable waiting and observable failed generations.

Only positively identified owned databases may be removed. Borrowed/protected targets never qualify. A held session lock is the only proof that a lease is live; cleanup skips live and preserved leases, reports a record whose lock is free as orphaned, removes orphans only on explicit apply, previews before applying, and refuses ambiguous crash windows. Use ordinary PostgreSQL durability. PostgreSQL documents the role-specific settings permission boundary in its [ALTER ROLE reference](https://www.postgresql.org/docs/18/sql-alterrole.html).

Cleanup preview validates an existing catalog without creating one and reads candidates in bounded pages. Apply selects concrete allocation IDs, takes their generation lock exclusively, then checks the lease lock and current database identity again; preview results are never deletion authority. A missing bound database can be marked released idempotently, while an allocation without a bound OID remains ambiguous even if its name exists.
PostgreSQL's [`DROP DATABASE` reference](https://www.postgresql.org/docs/18/sql-dropdatabase.html) limits `FORCE`: prepared transactions, active logical replication slots, and subscriptions can still block removal. Hinagata leaves such records inspectable as cleanup failures.

A caller-supplied classifier identifies failure values without changing them. The policy may preserve those values or thrown callback failures; detached acquisition records a retained clone after setup. Both are released by explicit lease ID, with the same lock and positive-ownership checks as orphan cleanup. Cleanup diagnostics accompany returned values separately, while a thrown callback keeps its original exception.

An optional trusted clone preparation hook uses setup access after clone grants and settings and before scenario fixtures. It runs for every new clone, including clones of a reused baseline. The hook is kept on the in-memory baseline handle and does not affect the sealed template fingerprint; a hook failure prevents callback handoff and triggers ownership-checked release.

Baseline retirement takes the generation lock exclusively, rechecks the generation record and positive database identity, records Retiring before the nontransactional drop, and leaves that record as a tombstone for issued clone references. Existing clones remain independent of the removed template. A stale handle fails the Ready check, while a later ensure call may build a new generation for the same fingerprint.

Fresh maintenance catalogs use format 2. An owned format-1 catalog upgrades under the bootstrap transaction and advisory lock, preserving its cluster UUID and records while adding diagnostic columns to generations and allocations. Read-only inspection reports that an upgrade is required without changing the schema. Failed builds and interrupted builders record a bounded non-secret reason; failed clone drops retain a diagnostic alongside their catalog state.

## Consequences

Warm runs amortize migration/base loading. Sealed baselines are cluster-local snapshots; multiple fingerprinted variants allow a frequently reused bulk scenario to be loaded once. Cloning copies data and is not promised constant-time. Portable dump snapshots are deferred. Opaque commands need an explicit trustworthy revision or force a rebuild. Hinagata reapplies database grants and settings to clones; schema privileges copied with a template are still asserted from the declaration for consistency. Applications own global roles. Crashes can leave inspectable resources rather than risk guessed deletion. Snapshot portability and schema-reset shortcuts await measured need. Precreated spare clones remain an experiment pending evidence that clone allocation dominates; idle sessions or elapsed time alone never authorize reclaiming a live lease. See the [prior-art review](../research/prior-art.md).
