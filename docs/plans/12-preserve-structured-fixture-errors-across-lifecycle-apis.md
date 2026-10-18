---
id: 12
slug: preserve-structured-fixture-errors-across-lifecycle-apis
title: "Preserve structured fixture errors across lifecycle APIs"
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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-18T21:49:09Z
      mode: "implement"
      note: "Preserve safe structured load failures through lifecycle, manager, and CLI APIs."
intention: "intention_01m58e4vxke9stryg9na9xc9em"
---

# Preserve structured fixture errors across lifecycle APIs


This ExecPlan is a living document. Update milestone evidence, material discoveries, decisions, and outcomes during implementation. Promote durable decisions into the relevant local ADRs before completion.


## Purpose / Big Picture


Fix audit finding F7 (P2): a failing base or scenario fixture must retain its safe structured cause through baseline preparation, lease acquisition, manager wrappers, and CLI output. Callers should identify the fixture, step, phase, SQLSTATE, and rollback diagnostic without parsing generic text. Keep callback results, cleanup failures, and asynchronous exceptions distinct.


## Progress


- [x] M1: Public baseline/lease errors retain structured load context without exposing fixture data or credentials.
- [x] M2: Manager and CLI consumers report matching context, with primary and cleanup failures kept separate.

Accepted 2026-10-18: the original lease path fails the primary-SQLSTATE regression. The repaired path preserves matching context from direct loading through baseline, lease, and manager APIs for SQL, COPY, and deferred COMMIT failures. Test-owned backend termination plus a prepared transaction proves independent rollback/release diagnostics and explicit recovery. CLI tests cover db prepare/acquire/with, fixture validate, direct loading, JSON/plain output, zero-based steps, unattributed commit failures, and unique data/password/argument redaction sentinels. The full combined MasterPlan gate passes, including every example and benchmark build, both PostgreSQL transports, core/process tests, CLI suites, conventions, docs, and whitespace checks.


## Surprises & Discoveries


A forced native disconnect can lose the server SQLSTATE before libpq delivers a result; preserve Nothing and the original load phase rather than inventing a code. A prepared transaction independently blocks clone DROP, proving nested rollback and outer release diagnostics survive together and remain recoverable. Final integration also tightened cancellation success boundaries so the new error plumbing cannot let a first signal escape a finishing supervisor.


## Decision Log


2026-10-18: Retain nested safe load context and independent cleanup diagnostics instead of exposing raw server text or replacing public errors with unstructured messages. Preserve high-level CLI error identities while adding detailed context.


## Outcomes & Retrospective


F7 is fixed with exported FixtureLoadContext/loadErrorContext, optional context on BaselineError and LeaseError, consistent primary SQLSTATE, and independent rollback/clone-release diagnostics. Manager forwarding and the CLI preserve the safe context; existing lifecycle codes and JSON formatVersion 1 remain stable with additive fields. Public Haskell record construction must initialize the new optional field. All consumers compile. ADR 3 and API/CLI documentation record the contract; no new exception conversion, dependency, catalog migration, public fault switch, or release work was introduced.


## Context and Orientation


`hinagata-postgres/src/Hinagata/Postgres/Error.hs` exposes LoadError containing phase, fixture, stepIndex, cause, sqlState, targetIdentity, and cleanupFailure. `hinagata-postgres/src/Hinagata/Postgres/Baseline.hs` currently replaces a base-load failure with BaselineError "base fixture load failed" Nothing. `hinagata-postgres/src/Hinagata/Postgres/Lease.hs` replaces a scenario failure with a generic LeaseError, discarding that context. Manager wrappers are in `hinagata-postgres/src/Hinagata/Postgres/Manager.hs`. CLI mapping lives in `hinagata-cli/src/Hinagata/Cli/Output.hs`, baseline preparation in `hinagata-cli/src/Hinagata/Cli/Command.hs`, and dispatch in `hinagata-cli/app/Main.hs`.

The native loader already excludes raw server messages because these may contain row values. Its SQLSTATE, fixture name, step index, phase, and generic cause are useful without exposing those messages. [ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md) keeps the CLI thin and credentials isolated. [ADR 2](../adr/2-stream-fixtures-through-private-postgresql-sessions.md) requires native failure/rollback reporting. [ADR 3](../adr/3-sealed-baselines-and-positive-database-ownership.md) keeps cleanup diagnostics separate from callback values and original exceptions.

The working directory for this plan is the Hinagata repository root, `/Users/shinzui/Keikaku/bokuno/hinagata` in the authoring checkout. `hinagata-core` compiles fixture directories into captured plans; `hinagata-postgres` loads them and manages owned database clones; `hinagata-cli` adapts these libraries to commands. A baseline is a sealed template database. A lease is exclusive use of a clone with recorded cleanup responsibility. SQLSTATE is PostgreSQL's five-character error code and does not contain row values.


## Plan of Work


M1 adds an optional structured fixture-load context to BaselineError and LeaseError. Prefer a shared exported FixtureLoadContext in `Hinagata.Postgres.Error` containing LoadPhase, Maybe FixtureName, Maybe Int stepIndex, Maybe Text sqlState, safe Text cause, and Maybe Text rollbackFailure. Construct it centrally from LoadError; do not copy the endpoint's targetIdentity into lifecycle diagnostics, where it is unnecessary. Keep the existing high-level lifecycle cause and sqlState fields for common inspection, copying the primary SQLSTATE consistently. Add Nothing at non-load constructor sites and preserve preparationContext unchanged. Update all construction, pattern matching, Show/redaction tests, examples, and benchmark consumers in the same change. Public record constructor changes are source-visible; document the field and conversion rather than leaving partial call-site migrations.

Keep rollbackFailure inside the nested load context and outer clone-release cleanupFailure independent. `mergeCleanup`, completion helpers, and manager forwarding must retain primary context when attaching a second diagnostic. No catch-all exception conversion is part of this plan: asynchronous exceptions continue to propagate according to the cancellation stream. Begin with a direct load and a lease scenario hitting the same constraint so the producer and public consumer are tested together before extending all command forms.

M2 updates CLI conversion to expose the actual fixture, zero-based step index, load phase, SQLSTATE, and rollback failure for both baseline and scenario errors. Preserve the existing top-level lifecycle error code/phase for automation, adding a nested load-context object for details instead of changing its meaning. Reuse existing fixture/sqlState/step fields where semantically applicable, and keep high-level messages generic. Ensure `prepareBaseline` in Command and the explicit constructors in Main do not discard the new context. Plain output should identify the failing fixture/step without raw SQL, values, child arguments, password-bearing strings, or server exception text. Document the schema addition and Haskell record changes in `docs/user/cli.md` and `docs/integration.md`; preserve existing JSON formatVersion unless an incompatible representation actually becomes necessary. Amend the ADR error-propagation contract on implementation.


## Concrete Steps


Run these commands from the repository root in its development environment (`nix develop` if the tools are not already available). First add the stated failing regressions, then implement the fix and rerun the relevant commands. Do not use a caller-owned database for these tests; leave `HINAGATA_TEST_PGHOST` unset so the scripts create disposable clusters.

```bash
cabal test hinagata-core-test hinagata-cli-process-test --test-show-details=direct
bash scripts/test-postgres.sh
cabal build all --enable-tests --enable-benchmarks
bash scripts/test-cli.sh
bash scripts/test-postgres.sh --cli
```

Cabal tests must finish with `PASS`; shell integration scripts must exit zero and print their final passed message. Record the regression names and concise actual outcomes in this plan when accepted. Existing tests passing without the new reproductions is insufficient.


## Validation and Acceptance


A base fixture with a duplicate key reports its fixture, zero-based failing step, ExecuteSql phase, and SQLSTATE 23505 through ensureBaseline and `db prepare --json`. A failing scenario carries equivalent information through withDatabaseClassified, manager APIs, `db acquire`, `db with`, and `fixture validate`. Include COPY failure and a deferred constraint failing at CommitLoad so no caller assumes every failure is ExecuteSql. Preserve fixture/step Nothing when a commit failure cannot be attributed to one step.

When rollback and clone release both fail, the original phase/SQLSTATE remain intact and both cleanup diagnostics are separately inspectable. Use existing internal fault seams or test-owned database faults; do not add a public fault-injection option. A synchronous callback result with cleanup failure still returns that result with its diagnostic. ThreadKilled/CommandCancelled remains an exception or the appropriate cancelled CLI outcome, never a nested operational load error. Redaction tests place unique secret sentinels in fixture values, supplied credentials, and child arguments and assert they do not appear in Haskell Show or CLI JSON/plain diagnostics. Existing JSON consumers and all example/benchmark components must compile.


## Idempotence and Recovery


The tests must be repeatable with fresh temporary fixture directories, unique database/catalog identities, and cleanup installed before starting servers or workers. Every intentionally blocked operation needs a separate controlling connection or test signal, a bounded wait, and teardown even after assertion failure. Release only resources the test created. Never remove unrelated databases or use a name alone as deletion authority. If interrupted, stop only the test's disposable cluster, inspect its logs, and rerun. Do not delete or rewrite existing user changes. No package publication, release metadata, or dependency upgrades are required.


## Interfaces and Dependencies


No hard prerequisite. Soft prerequisites are `docs/plans/10-propagate-cancellation-through-commands-and-resource-lifetimes.md` for settled exception semantics and `docs/plans/11-apply-postgresql-role-settings-without-changing-their-meaning.md` for avoiding overlapping Baseline edits. This plan owns the shared FixtureLoadContext type, the two public record extensions, central conversion functions, and CLI error mapping. Other plans retain their behavior and feed errors into this representation. No dependency on consumer database drivers, a logging framework, or a schema migration is introduced.

Use `mori registry search <dependency>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>` before selecting dependency APIs. Read located source; if the registry has no source, consult authoritative upstream documentation and record the gap. Do not search `/nix/store` or the filesystem root. Keep cross-repository durable references canonical. No dependency bounds or pins change under this plan; if one becomes necessary, first verify the released registry version and upstream tags. Implementation commits use Conventional Commits and include this file's `ExecPlan:` trailer, `MasterPlan: docs/masterplans/2-fix-code-and-api-audit-findings.md`, and `Intention: intention_01m58e4vxke9stryg9na9xc9em`.
