# ADR 3: Sealed baselines and positive database ownership

Status: Accepted

Date: 2026-09-26

Amended: 2026-10-01 (lock modes, generation preparation, explicit schema grants, orphan classification)

## Context

Reuse must not silently test stale migrations or share scenario state. CREATE/DROP DATABASE are nontransactional, and copying a template requires no connected sessions.

## Decision

Build immutable generations on the existing cluster; migrate, load, verify, disconnect, seal, then publish. Fingerprints cover real migration identity, frozen base sources, configuration, and server requirements. Reuse requires matching cluster/catalog/database identity. A maintenance catalog records allocation intent, identity, baseline/run association, and active/detached/preserved state. Advisory locks coordinate build, acquisition, retirement, and cleanup: a generation's lock is taken in shared mode by clone allocation and exclusively by build, retirement, and cleanup, matching PostgreSQL's own share lock on a template so concurrent clones are never serialized by Hinagata. The administration role owns every database Hinagata creates and applies declared database grants, schema grants, and role settings to a fresh generation before the application migration hook, as well as to every clone. PostgreSQL 15 and later give non-owners no `CREATE` on `public`; database `CREATE` alone does not confer that schema privilege, so setup roles migrating into `public` need an explicit schema grant.

Store a non-secret fingerprint manifest, including state-affecting role/configuration and hook revisions, with explainable reuse/build outcomes. Reusable handles avoid rereading fixture bytes but do not bypass database identity checks. Baseline/scenario composition resolves base roots first and skips only that verified prefix on a fresh clone; conflicting shared definitions are errors. Concurrent construction has deadline-bound cancellable waiting and observable failed generations.

Only positively identified owned databases may be removed. Borrowed/protected targets never qualify. A held session lock is the only proof that a lease is live; cleanup skips live and preserved leases, reports a record whose lock is free as orphaned, removes orphans only on explicit apply, previews before applying, and refuses ambiguous crash windows. Use ordinary PostgreSQL durability.

## Consequences

Warm runs amortize migration/base loading. Sealed baselines are cluster-local snapshots; multiple fingerprinted variants allow a frequently reused bulk scenario to be loaded once. Cloning copies data and is not promised constant-time. Portable dump snapshots are deferred. Opaque commands need an explicit trustworthy revision or force a rebuild. Hinagata reapplies database grants and settings to clones; schema privileges copied with a template are still asserted from the declaration for consistency. Applications own global roles. Crashes can leave inspectable resources rather than risk guessed deletion. Snapshot portability and schema-reset shortcuts await measured need. Precreated spare clones remain an experiment pending evidence that clone allocation dominates; idle sessions or elapsed time alone never authorize reclaiming a live lease. See the [prior-art review](../research/prior-art.md).
