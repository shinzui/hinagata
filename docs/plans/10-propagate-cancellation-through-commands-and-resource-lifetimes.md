---
id: 10
slug: propagate-cancellation-through-commands-and-resource-lifetimes
title: "Propagate cancellation through commands and resource lifetimes"
kind: exec-plan
created_at: 2026-10-18T21:18:05Z
master_plan: "docs/masterplans/2-fix-code-and-api-audit-findings.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-18T21:18:05Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-18T21:23:51Z
      mode: "other"
      note: "Complete audit remediation scope, regression acceptance, integration ownership, and Mina intention linkage."
intention: "intention_01m58e4vxke9stryg9na9xc9em"
---

# Propagate cancellation through commands and resource lifetimes


This ExecPlan is a living document. Update milestone evidence, material discoveries, decisions, and outcomes during implementation. Promote durable decisions into the relevant local ADRs before completion.


## Purpose / Big Picture


Fix audit findings F2 (P1), F4 (P2), and F5 (P2) as one end-to-end cancellation contract. SIGINT/SIGTERM must stop active CLI work before uncommitted fixture writes are committed. Library cancellation must propagate after bounded cleanup, and a cancelled connection attempt must release its native handle immediately rather than wait for garbage collection.


## Progress


- [ ] M1: Interrupted connection acquisition closes its socket before returning, including the acquisition-to-bracket boundary.
- [ ] M2: Cancellation during lease completion propagates while preserving recoverable ownership state and synchronous cleanup diagnostics.
- [ ] M3: Command-wide cancellation stops direct loads and database waits, settles child/lease cleanup, and reports 130/143 without success output.

Implementation has not started. The audit observations below describe the original defect, not acceptance of a fix.


## Surprises & Discoveries


None recorded during implementation yet.


## Decision Log


2026-10-18: Treat CLI signal propagation, exception-safe connection ownership, and cancellation during lease completion as one functional stream. Fixing only the command supervisor would expose the native leaks and swallowed exceptions to more callers.


## Outcomes & Retrospective


Pending implementation and acceptance evidence.


## Context and Orientation


`hinagata-postgres/src/Hinagata/Postgres/Internal/Libpq.hs` opens before installing the `withSession` bracket and catches only IOException while polling. `hinagata-postgres/src/Hinagata/Postgres/Lease.hs` catches SomeException around `completeValue` and currently converts ThreadKilled into a returned cleanup diagnostic. `hinagata-cli/src/Hinagata/Cli/Process.hs` installs one command-wide signal scope, but only registered child supervisors observe its marker. `hinagata-cli/app/Main.hs` directly calls `loadInto` and several catalog operations without supervising them against that marker. `hinagata-cli/src/Hinagata/Cli/Validation.hs` already supervises validation workers; `hinagata-cli/src/Hinagata/Cli/Command.hs` preserves typed preparation failures and uncertain process cleanup.

Audit evidence: SIGTERM during a four-second direct load allowed its later CREATE TABLE to commit and printed ok:true before exit 143. Killing a lease worker blocked on a catalog row lock returned Right LeaseOutcome with LeaseCleanupFailed instead of throwing. Timing out a connection to a stalled authentication peer returned Nothing while the peer socket remained open.

[ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md) requires one signal scope, first-signal semantics, bounded child shutdown, and retention when child stoppage is uncertain. [ADR 2](../adr/2-stream-fixtures-through-private-postgresql-sessions.md) assigns native handle lifetime and transaction rollback to the session adapter. [ADR 3](../adr/3-sealed-baselines-and-positive-database-ownership.md) requires positive ownership for cleanup and preservation of original callback exceptions. Maintain all three guarantees.

The working directory for this plan is the Hinagata repository root, `/Users/shinzui/Keikaku/bokuno/hinagata` in the authoring checkout. `hinagata-core` compiles fixture directories into captured plans; `hinagata-postgres` loads them and manages owned database clones; `hinagata-cli` adapts these libraries to commands. A baseline is a sealed template database. A lease is exclusive use of a clone with recorded cleanup responsibility. SQLSTATE is PostgreSQL's five-character error code and does not contain row values.


## Plan of Work


M1 brackets native allocation from the instant `PQ.connectStart` returns a handle. Mask the short ownership-transfer region, restore interruptibility during polling, and finish the handle on every exceptional path, including asynchronous exceptions. Transfer ownership to Session exactly once and install its release handler before restoring the user callback. Do not make network waits uninterruptibly masked. Add a controlled stalled peer or internal test seam that observes connection close without a GC request; also test successful open/close, ordinary connect failure, timeout, and callback exceptions. Keep such seams private.

M2 distinguishes asynchronous exceptions from synchronous completion failures in `withDatabaseClassified`. After cleanup/recovery bookkeeping, rethrow the original asynchronous exception; continue returning a callback value plus diagnostic for synchronous cleanup errors. Do not convert loss of cancellation into a successful value, discard the primary exception, or grant deletion authority after ownership loss. Test a controller-held row lock on the allocation during release, issue cancellation only after the update is demonstrably blocked, release the controller in teardown, and inspect the recorded clone afterward. Retained-policy completion and manager permits also need coverage. Cleanup may leave an inspectable owned allocation when a connection is retired; it must not claim release unless confirmed.

M3 adds one root command supervisor that observes the existing CancellationScope throughout native/database/file work and cancels the command worker once with CommandCancelled for the first signal. Reuse the existing signal handler; never install one per worker or child. Join the worker's cleanup before choosing exit status, and retain typed preparation outcomes and uncertain child-cleanup evidence. In particular, a generic cancellation must not overwrite PreparationFailure releaseSafe=False or trigger release under a possibly live child. Coordinate with existing validation supervision to avoid a second asynchronous interruption of cleanup. Start with direct-load cancellation, then cover a blocked baseline lock and acquisition, as well as current migration/preparation/db-with subprocess regressions. Check cancellation before rendering success, but do not claim cancellation can undo an already committed transaction.

Use deterministic test barriers: a separate observer confirms the target query or catalog lock wait before signalling. Keep only bounded polling with explicit failure limits. Update CLI cancellation docs and API exception Haddock. Amend ADRs 1–3 with the accepted resource-transfer and first-cancellation rules; do not rewrite their ownership boundaries.


## Concrete Steps


Run these commands from the repository root in its development environment (`nix develop` if the tools are not already available). First add the stated failing regressions, then implement the fix and rerun the relevant commands. Do not use a caller-owned database for these tests; leave `HINAGATA_TEST_PGHOST` unset so the scripts create disposable clusters.

```bash
cabal test hinagata-core-test hinagata-cli-process-test --test-show-details=direct
bash scripts/test-postgres.sh
cabal build exe:hinagata
bash scripts/test-postgres.sh --cli
bash scripts/test-cli.sh
```

Cabal tests must finish with `PASS`; shell integration scripts must exit zero and print their final passed message. Record the regression names and concise actual outcomes in this plan when accepted. Existing tests passing without the new reproductions is insufficient.


## Validation and Acceptance


For native acquisition, the stalled peer sees EOF by the time the timeout/cancellation returns, without forcing GC; normal callbacks still receive an open session and close it on exit. For completion cancellation, `try @SomeException` observes the original asynchronous exception, never an ordinary Right LeaseOutcome. Manager active/setup permits are reusable afterward, and any leftover clone is recoverable only through existing ownership checks. Synchronous DROP failure still returns its separate diagnostic alongside the original callback value.

For CLI direct loading, send INT and TERM after a fixture has performed a transactional write and entered a long pg_sleep. Exit must be 130/143 within a documented test bound smaller than the query duration, with no success JSON and no persisted fixture writes. Prefer an original sentinel row to distinguish rollback from deletion/reset. A blocked baseline lock must also cancel before its normal operation deadline. Repeated signals must not interrupt bounded shutdown a second time. Existing tests for exit-zero signal handlers, concurrent validation, unsafe child cleanup, retention, deadlines, ownership loss, and child reaping must remain green. A signal arriving after a confirmed commit may change command exit reporting but cannot promise rollback of that commit.


## Idempotence and Recovery


The tests must be repeatable with fresh temporary fixture directories, unique database/catalog identities, and cleanup installed before starting servers or workers. Every intentionally blocked operation needs a separate controlling connection or test signal, a bounded wait, and teardown even after assertion failure. Release only resources the test created. Never remove unrelated databases or use a name alone as deletion authority. If interrupted, stop only the test's disposable cluster, inspect its logs, and rerun. Do not delete or rewrite existing user changes. No package publication, release metadata, or dependency upgrades are required.


## Interfaces and Dependencies


No hard prerequisite. Soft ordering follows `docs/plans/9-honor-explicit-postgresql-connection-targets.md`; that plan owns connection options while this one owns their resource lifetime. This plan owns asynchronous exception behavior and command supervision, including interactions with `Manager`, `LeaseOutcome`, and typed PreparationFailure. Keep public callback signatures where possible. `docs/plans/12-preserve-structured-fixture-errors-across-lifecycle-apis.md` later extends typed operational errors and must never wrap asynchronous exceptions as such errors. Test edits belong in `hinagata-postgres/test/Main.hs`, `hinagata-cli/test/Main.hs`, and `scripts/test-cli-postgres.sh`; any new test component or private seam must be registered in the appropriate Cabal file.

Use `mori registry search <dependency>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>` before selecting dependency APIs. Read located source; if the registry has no source, consult authoritative upstream documentation and record the gap. Do not search `/nix/store` or the filesystem root. Keep cross-repository durable references canonical. No dependency bounds or pins change under this plan; if one becomes necessary, first verify the released registry version and upstream tags. Implementation commits use Conventional Commits and include this file's `ExecPlan:` trailer, `MasterPlan: docs/masterplans/2-fix-code-and-api-audit-findings.md`, and `Intention: intention_01m58e4vxke9stryg9na9xc9em`.
