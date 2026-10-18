# ADR 1: Library boundary and service-owned PostgreSQL

Status: Accepted

Date: 2026-09-26

Amended: 2026-10-18 (command-scoped cancellation and supervised clone preparation)

Amended: 2026-10-18 (declared content-derived baseline hook identities)

## Context

The old spec predates `mori://shinzui/hurl-workbench`. Services already bootstrap PostgreSQL, commonly on a Unix socket. The user wants a Haskell library and Settei settings.

## Decision

Hinagata supplies pure fixture planning, native PostgreSQL loading, and owned database leases with a thin CLI. The caller owns PostgreSQL and service startup. Direct loading grants no deletion authority. Hurl-workbench owns HTTP execution, readiness, and reporting. A generic bracketed command encloses the external test lifecycle within a database lease.

Configuration uses Settei; library callers can pass resolved values. Public types are independent of the consumer's driver/effect system. Keiro integration uses application migration/verification hooks and public runtime APIs, respecting `mori://shinzui/keiro/okf/adrs/concepts/ADR-9` and `mori://shinzui/keiro/okf/adrs/concepts/ADR-28`.

Development tooling is bootstrapped by `mori://shinzui/seihou-modules/templates/nix-haskell-flake`, with its managed lock/modules preserved and project customizations in `flake.module.nix`. This is a development dependency; production library calls do not bootstrap PostgreSQL.

Administration, setup, and application endpoints have explicit roles. Application handoff never implicitly uses administrative credentials. Suite-scoped resource limits and result classification belong to the library; adapters may map test-framework outcomes without introducing a framework dependency. Service bootstrap retains global-role ownership.

The CLI adapts executable migration, verification, and per-clone preparation commands into the library's setup-endpoint hooks. Baseline commands have manual or content-derived revisions and deadlines; clone preparation has a deadline and is excluded from baseline identity. A command path without a revision cannot authorize persistent baseline reuse. `db with` passes only the application endpoint through a fixed PostgreSQL environment overlay and, when needed, a private password file. It owns a generic child process group, forwards cancellation, reaps descendants before lease release, and retains the lease if process cleanup is uncertain. Workbench retains ownership of readiness, Hurl execution, and its nested service process group.

The implementation in [ExecPlan 6](../plans/6-expose-clone-preparation-hooks-through-the-cli.md) assigns SIGINT/SIGTERM handlers to one explicit CLI command scope shared by migration, verification, clone preparation, and application subprocesses. Concurrent child supervisors register with that scope and never install or restore process-wide handlers independently. The first signal cancels active work and stops further validation admission; the command settles bounded process and lease cleanup before restoring prior handlers and returning 130/143. Child registration must observe cancellation that races with spawning. Per-lease errors and uncertain-cleanup retention remain independent of the shared signal, and repeated signals must not interrupt cleanup again. This allows concurrent fixture validation without losing cancellation when children finish out of order. Internal fault-injection seams test uncertain cleanup without exposing an environment or configuration bypass. Supervised preparation raises typed, credential-free failures at the library hook boundary, preserving run/lease context and release safety while retaining the legacy callback signature. The adapter masks the short supervision-result/classification boundary while blocking waits remain interruptible, so cancellation cannot replace unsafe-cleanup classification with an ordinary safe failure. Hook cancellation remains failure even when a signal handler exits zero. Seed output stays on stderr; structured reports contain safe reasons only.

The [standards applicability audit](../research/haskell-standards-audit.md) defines the cross-package Haskell baseline and selected CLI patterns. Informational CLI paths are offline; Hurl standards apply to example services through workbench. Public module boundaries also prevent transitive generic-lens orphan exposure to consumers.

Hinagata core exposes a reusable versioned named-content revision helper, while CLI configuration and subprocess assembly remain adapters. Services declare every relevant file and non-secret value and pass those inputs to their commands themselves. The CLI selects executable bytes only on request and derives ordinary revision strings for the existing baseline interface. Selected files are read with bounded memory through a nonblocking open and regular-file descriptor check, so a pipe cannot hang identity capture. Clone preparation stays outside this identity. Manual revisions remain supported for remote or secret-controlled effects; neither mode may imply discovery of arbitrary dependencies or protection of hashed secrets.

A root command supervisor covers native work and catalog waits. First-signal delivery ownership is captured atomically with the signal: active child and validation supervisors finish through their typed outcomes, while the root interrupts other work exactly once. Delegate only while an actual supervisor owns delivery, and recheck cancellation after a successful delegated outcome and before rendering success. This closes the boundary where a signal could otherwise be latched just as supervision ends. The root joins cleanup before reporting 130/143. Repeated signals cannot interrupt shutdown again or erase uncertain child-stoppage evidence. A signal after a confirmed commit cannot undo that commit.

## Consequences

Existing PostgreSQL is reused without startup cost. Services receive clone settings before startup. No Hurl parser, invented workbench hook, or private runtime-table mutation is introduced. Portable dump snapshots, provisioning, and general orchestration are deferred. Cluster-local baseline snapshots are included under [ADR 3](3-sealed-baselines-and-positive-database-ownership.md).
