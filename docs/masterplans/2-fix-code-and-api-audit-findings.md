---
id: 2
slug: fix-code-and-api-audit-findings
title: "Fix code and API audit findings"
kind: master-plan
created_at: 2026-10-18T21:17:58Z
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-18T21:17:58Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-18T21:23:51Z
      mode: "other"
      note: "Complete audit remediation scope, regression acceptance, integration ownership, and Mina intention linkage."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-18T21:27:02Z
      mode: "implement"
      note: "Implement audit repairs in serial child order and reconcile acceptance evidence."
intention: "intention_01m58e4vxke9stryg9na9xc9em"
---

# Fix code and API audit findings


This MasterPlan coordinates fixes for all seven findings from the 2026-10-18 code/API audit. Its registry owns child status; child ExecPlans own milestones and implementation evidence. This planning task creates the documents, not the fixes. Intention `intention_01m58e4vxke9stryg9na9xc9em` was created with `mina ci --json` at the user's request.


## Vision & Scope


Fixture loads preserve their transaction boundary, explicit PostgreSQL endpoints cannot be redirected by ambient routing defaults, and cancellation stops active work while preserving cleanup safety. Role settings keep their intended PostgreSQL meaning, and callers receive useful safe failure context across the library and CLI.

Scope includes the six reproduced bugs and the structured-error API issue below, their regression tests, public API/documentation adjustments needed by those fixes, and fingerprint compatibility needed to avoid stale baseline reuse. Package publication, release versions/changelogs/tags, release tooling, dependency refreshes, provisioning, and unrelated refactors are excluded. Existing caller ownership, private sessions, child-process retention, and secret redaction remain required.

F1 (P1) is the form-feed transaction-control bypass in `hinagata-core/src/Hinagata/Fixture/SqlPolicy.hs`: an accepted COMMIT step persisted an earlier write even though a later division-by-zero step failed. F2 (P1) is missing CLI signal propagation to native direct loads in `hinagata-cli/app/Main.hs`: SIGTERM during pg_sleep still allowed later SQL to commit, printed ok:true, then exited 143. F3 (P1) is ambient PGHOSTADDR changing the explicit transport through `Hinagata.Connection`/`Internal.Libpq`: a nonexistent socket target successfully used a reachable TCP proxy.

F4 (P2) is cancellation swallowed by the SomeException handler around lease completion in `hinagata-postgres/src/Hinagata/Postgres/Lease.hs`: killing a worker blocked on its cleanup update returned a normal LeaseOutcome. F5 (P2) is incomplete acquisition cleanup in `hinagata-postgres/src/Hinagata/Postgres/Internal/Libpq.hs`: a cancelled stalled connection retained its socket beyond return. F6 (P2) is whole-value literal quoting in `hinagata-postgres/src/Hinagata/Postgres/Internal/Access.hs`: search_path=public,pg_catalog became one quoted schema name. F7 (P2) is Baseline/Lease replacing structured LoadError with generic text, losing phase, fixture, step, SQLSTATE, and rollback context.

These observations were reproduced or traced in the authoring audit. Core, CLI-process, PostgreSQL, and CLI/PostgreSQL suites passed on the original code, so existing suite success alone cannot establish that the defects are fixed. Disposable audit servers were shut down. Child plans recreate the observations in maintained tests and do not depend on temporary audit scripts or this conversation.


## Decomposition Strategy


Five streams follow observable behavior rather than individual files: lexical transaction protection (F1), explicit routing (F3), cancellation/resource lifetime (F2/F4/F5), setting semantics and cache identity (F6), and error propagation (F7). Cancellation stays together because adding a CLI cancellation supervisor without fixing handle lifetime and completion exceptions would expose the remaining defects to more callers. Role-setting repair includes cache invalidation because a correctly changed setter alone cannot repair reused sealed databases. A separate umbrella testing plan would duplicate each stream's acceptance, so final combined verification stays here.

Relevant local decisions are [ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md), which keeps PostgreSQL service-owned, the CLI thin, and child cancellation command-scoped; [ADR 2](../adr/2-stream-fixtures-through-private-postgresql-sessions.md), which assigns one transaction, protocol ownership, and handle lifetime to the private adapter; and [ADR 3](../adr/3-sealed-baselines-and-positive-database-ownership.md), which requires role-owned settings, immutable fingerprinted baselines, positive deletion authority, and separate cleanup diagnostics. All three were consulted. No new cross-repository architecture decision is required for these local repairs. At implementation, follow `agents/skills/exec-plan/ADR.md` before changing records and preserve the repository's established ADR format.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 8 | SQL transaction protection | [8-preserve-fixture-atomicity-across-sql-whitespace.md](../plans/8-preserve-fixture-atomicity-across-sql-whitespace.md) | None | None | Complete |
| 9 | Explicit connection targets | [9-honor-explicit-postgresql-connection-targets.md](../plans/9-honor-explicit-postgresql-connection-targets.md) | None | EP-8 | Complete |
| 10 | Cancellation and resource lifetimes | [10-propagate-cancellation-through-commands-and-resource-lifetimes.md](../plans/10-propagate-cancellation-through-commands-and-resource-lifetimes.md) | None | EP-9 | Complete |
| 11 | Role-setting semantics and cache identity | [11-apply-postgresql-role-settings-without-changing-their-meaning.md](../plans/11-apply-postgresql-role-settings-without-changing-their-meaning.md) | None | None | Not Started |
| 12 | Structured lifecycle errors | [12-preserve-structured-fixture-errors-across-lifecycle-apis.md](../plans/12-preserve-structured-fixture-errors-across-lifecycle-apis.md) | None | EP-10, EP-11 | Not Started |

Status values are Not Started, In Progress, Complete, or Cancelled. F1 maps to EP-8; F3 to EP-9; F2/F4/F5 to EP-10; F6 to EP-11; F7 to EP-12. Every finding has one accountable owner.


## Dependency Graph


Default implementation order is EP-8, EP-9, EP-10, EP-11, then EP-12. No child requires another child's new artifact to begin, so there are no hard dependencies. Soft ordering closes the high-priority transaction/routing defects first and settles exception behavior before expanding error records. EP-11 is independently verifiable; its default position avoids simultaneous changes to Baseline and lifecycle tests.

Integration relationships are EP-8 with EP-10/EP-12 for transactional failures, EP-9 with EP-10 for the connection adapter, and EP-10/EP-11 with EP-12 for lifecycle errors. These relationships require reconciliation at the final gate, not pretend prerequisites. Independent work is possible if separately authorized and shared file ownership is coordinated; this plan does not require delegation. Keep serial execution as the default.


## Integration Points


EP-9 owns endpoint option semantics at `Hinagata.Connection.renderConnectionString` and the native open boundary. EP-10 owns masking, ownership transfer, polling interruption, and Session release at that same boundary. Neither may mutate process-global environment to implement per-connection behavior. The representative combined proof is a cancelled native connection with conflicting ambient endpoint defaults; EP-10 owns that proof after both implementations exist.

EP-8 owns SQL policy and rejection before dispatch. EP-10 owns rollback on cancellation and acquisition deadlines. EP-12 owns typed operational failure context; it must not catch asynchronous exceptions into that context. Run one direct-load-to-lease constraint failure early in EP-12 before broadening error plumbing. Primary load errors, rollback diagnostics, clone-release errors, callback values, and uncertain child stoppage remain distinct throughout.

EP-11 owns setting interpretation and fingerprint-v2 compatibility in Baseline. It must preserve role-owned application without new administrative privileges and avoid reuse of v1 interpretations. EP-12 owns error record changes in Baseline/Lease and updates all consumers. Coordinate positional constructors and record patterns through full package compilation. The maintenance catalog format stays unchanged unless a separately justified requirement emerges; neither cache invalidation nor error propagation needs one.

Tests in `hinagata-postgres/test/Main.hs`, `hinagata-cli/test/Main.hs`, and `scripts/test-cli-postgres.sh` are shared. Each child owns the regressions for its findings and preserves the others. Test coordination must use observable barriers rather than unexplained sleeps. New test seams stay internal. Child subprocess supervisors must settle before safe clone release; uncertain stoppage retains the clone regardless of the new root command supervisor.

Durable exception/ownership rules belong in ADRs 1–3 when implemented. Endpoint routing goes in ADR 1 or 2, lexical transaction guarantees in ADR 2, and setting/fingerprint/error semantics in ADR 3. At completion, distill the accepted decisions and lessons from every child into the appropriate ADRs without copying task-local test transcripts.


## Progress


EP-8 and EP-9 are accepted with core, socket/TCP, and CLI/native regressions. EP-10 is also accepted, including cancelled acquisition under conflicting endpoint defaults and recovery after interrupted completion. Two children remain; EP-11 is next. No child is blocked by a hard dependency. This master plan is not complete until every child is accepted and the combined integration gate below passes.

The final gate runs from the repository root in the development environment with `HINAGATA_TEST_PGHOST` unset. Use fresh disposable clusters and retain concise evidence on the final combined tree:

```bash
cabal build all --enable-tests --enable-benchmarks
cabal test hinagata-core-test hinagata-cli-process-test --test-show-details=direct
bash scripts/test-postgres.sh
bash scripts/test-postgres.sh --tcp
bash scripts/test-cli.sh
bash scripts/test-postgres.sh --cli
python3 scripts/check_conventions.py
just check-docs
git diff --check
```

All tests/checks must pass. Reuse already recorded results from the same combined tree unless changes invalidate them. Verify the seven finding-specific acceptance outcomes, the endpoint-plus-cancellation integration proof, redaction, unchanged caller-owned data on rejected/cancelled loads, and recoverability of retained clones. Build examples and benchmarks through `cabal build all --enable-tests --enable-benchmarks` so public error changes cannot leave consumers broken. Do not run the aggregate release/package-publication workflow as part of this gate. Update registry and outcomes only after observed acceptance, then complete ADR distillation.


## Surprises & Discoveries


The original test suites passed despite the six demonstrated bugs. New behavior-specific regressions are therefore mandatory. Role-setting repair also needs semantic fingerprint invalidation; otherwise a matching sealed baseline can preserve the old behavior even after the setter changes. The child plan handles supported old/new comparisons explicitly.


## Decision Log


2026-10-18: Group CLI cancellation, lease-completion cancellation, and connection acquisition cleanup into EP-10. They form one exception/resource contract and must preserve uncertain-child retention together.

2026-10-18: Use five independently verifiable streams with a default serial order and explicit integration ownership, without artificial hard dependencies. Keep combined validation in this MasterPlan and regression ownership in each child.

2026-10-18: Include fingerprint semantic invalidation in the role-setting fix and safe nested error context in the API fix. Both are necessary to make the repaired behavior observable through existing baseline reuse and caller interfaces. Package release work remains excluded.


## Outcomes & Retrospective


Pending implementation. The planning deliverable is this coordination document and five self-contained child ExecPlans. No finding is claimed fixed. Record accepted behaviors, remaining limitations, and ADR updates here when all children and the final gate complete.
