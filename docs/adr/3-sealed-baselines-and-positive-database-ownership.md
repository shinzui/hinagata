# ADR 3: Sealed baselines and positive database ownership

Status: Accepted

Date: 2026-09-26

## Context

Reuse must not silently test stale migrations or share scenario state. CREATE/DROP DATABASE are nontransactional, and copying a template requires no connected sessions.

## Decision

Build immutable generations on the existing cluster; migrate, load, verify, disconnect, seal, then publish. Fingerprints cover real migration identity, frozen base sources, configuration, and server requirements. Reuse requires matching cluster/catalog/database identity. A maintenance catalog records allocation intent, identity, baseline/run association, and active/detached/preserved state. Advisory locks coordinate build, acquisition, retirement, and cleanup.

Only positively identified owned databases may be removed. Borrowed/protected targets never qualify. Cleanup skips active/preserved leases, previews before applying, and refuses ambiguous crash windows. Use ordinary PostgreSQL durability.

## Consequences

Warm runs amortize migration/base loading. Sealed baselines are cluster-local snapshots; multiple fingerprinted variants allow a frequently reused bulk scenario to be loaded once. Cloning copies data and is not promised constant-time. Portable dump snapshots are deferred. Opaque commands need an explicit trustworthy revision or force a rebuild. Applications reapply database-level grants/settings and own global roles. Crashes can leave inspectable resources rather than risk guessed deletion. Snapshot portability and schema-reset shortcuts await measured need.
