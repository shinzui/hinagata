---
id: 8
slug: preserve-fixture-atomicity-across-sql-whitespace
title: "Preserve fixture atomicity across SQL whitespace"
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

# Preserve fixture atomicity across SQL whitespace


This ExecPlan is a living document. Update milestone evidence, material discoveries, decisions, and outcomes during implementation. Promote durable decisions into the relevant local ADRs before completion.


## Purpose / Big Picture


Fix audit finding F1 (P1): transaction-control SQL must not pass fixture validation because of PostgreSQL whitespace. A rejected fixture must cause no database mutation, and an ordinary late failure must still roll back earlier SQL/COPY steps. This repairs the existing trusted-SQL lexical policy; it does not introduce a complete SQL parser or promise rollback of sequence/external effects.


## Progress


- [ ] M1: PostgreSQL whitespace cannot hide forbidden statements, while quoted/commented text remains accepted.
- [ ] M2: Native direct-load regressions prove rejection before mutation and rollback of valid multi-step fixtures.

Implementation has not started. The audit observations below describe the original defect, not acceptance of a fix.


## Surprises & Discoveries


None recorded during implementation yet.


## Decision Log


2026-10-18: Use the existing lexical validator and preserve its documented trusted-SQL scope. A full SQL parser would expand the work without being necessary to reject the demonstrated escape.


## Outcomes & Retrospective


Pending implementation and acceptance evidence.


## Context and Orientation


`hinagata-core/src/Hinagata/Fixture/SqlPolicy.hs` implements `checkSqlPolicy` and its statement-start scanner. It currently skips space, tab, carriage return, and newline, but a form feed resets statement-start state. `hinagata-core/src/Hinagata/Fixture/Bundle.hs` calls this check during capture before publishing a bundle. `hinagata-postgres/src/Hinagata/Postgres/Internal/Load.hs` executes each captured step inside one transaction. Tests live in `hinagata-core/test/Main.hs` and `hinagata-postgres/test/Main.hs`.

The audit created three SQL steps: create a table and insert one row; a form-feed byte followed by `COMMIT;`; then `SELECT 1/0;`. Compilation accepted the plan, execution returned SQLSTATE `22012`, and the earlier table and row remained committed. Recreate the byte with a Haskell byte string escape or a binary file write, not a literal backslash and letter f.

[ADR 2](../adr/2-stream-fixtures-through-private-postgresql-sessions.md) requires one transaction on an exclusive private connection and retirement of uncertain sessions. Keep its trusted-code limitation: quoted function bodies are not analyzed.

The working directory for this plan is the Hinagata repository root, `/Users/shinzui/Keikaku/bokuno/hinagata` in the authoring checkout. `hinagata-core` compiles fixture directories into captured plans; `hinagata-postgres` loads them and manages owned database clones; `hinagata-cli` adapts these libraries to commands. A baseline is a sealed template database. A lease is exclusive use of a clone with recorded cleanup responsibility. SQLSTATE is PostgreSQL's five-character error code and does not contain row values.


## Plan of Work


M1 changes the scanner's whitespace classification to match PostgreSQL's ASCII whitespace, including form feed and vertical tab. Retain the correct line-start behavior for psql-command rejection. Test every whitespace byte around the first keyword, after semicolons and comments, and between START/PREPARE and TRANSACTION. Exercise the existing forbidden keywords and positive cases containing those words inside single, escaped, double, and dollar quotes or comments. Avoid a broad Unicode whitespace predicate that accepts characters PostgreSQL does not treat as separators.

M2 adds the exact three-step reproduction through `compileFixtures` and the public loading path. The expected result is now `InvalidSql` before execution; a sentinel table remains unchanged and the new table does not exist. Separately run a permitted multi-step fixture with an early write and a late failure to prove rollback still works. Keep SQL/COPY ordering tests. Document the lexical boundary in `docs/user/fixtures.md` only where the current wording needs correction; amend ADR 2 if its durable lexical contract changes.


## Concrete Steps


Run these commands from the repository root in its development environment (`nix develop` if the tools are not already available). First add the stated failing regressions, then implement the fix and rerun the relevant commands. Do not use a caller-owned database for these tests; leave `HINAGATA_TEST_PGHOST` unset so the scripts create disposable clusters.

```bash
cabal test hinagata-core-test --test-show-details=direct
bash scripts/test-postgres.sh
python3 scripts/check_conventions.py
```

Cabal tests must finish with `PASS`; shell integration scripts must exit zero and print their final passed message. Record the regression names and concise actual outcomes in this plan when accepted. Existing tests passing without the new reproductions is insufficient.


## Validation and Acceptance


A fixture with a real form feed or vertical tab before COMMIT, ROLLBACK, COPY, or another forbidden statement fails capture with the appropriate policy error. Whitespace between START and TRANSACTION cannot bypass the check. Strings/comments containing the same bytes and words do not become false positives. Compilation failure sends no fixture SQL to PostgreSQL. For a permitted transaction with a later SQL or COPY error, the original database sentinel remains and all transactional fixture writes are absent.


## Idempotence and Recovery


The tests must be repeatable with fresh temporary fixture directories, unique database/catalog identities, and cleanup installed before starting servers or workers. Every intentionally blocked operation needs a separate controlling connection or test signal, a bounded wait, and teardown even after assertion failure. Release only resources the test created. Never remove unrelated databases or use a name alone as deletion authority. If interrupted, stop only the test's disposable cluster, inspect its logs, and rerun. Do not delete or rewrite existing user changes. No package publication, release metadata, or dependency upgrades are required.


## Interfaces and Dependencies


No hard or soft prerequisite. This plan owns lexical policy and its compiler/load regressions. Public `checkSqlPolicy`, `FixturePlan`, and load signatures remain unchanged. Its integration relationship with `docs/plans/10-propagate-cancellation-through-commands-and-resource-lifetimes.md` is the one-transaction contract; with `docs/plans/12-preserve-structured-fixture-errors-across-lifecycle-apis.md` it is preservation of failure phase and fixture/step information. Later plans consume these semantics without replacing the validator.

Use `mori registry search <dependency>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>` before selecting dependency APIs. Read located source; if the registry has no source, consult authoritative upstream documentation and record the gap. Do not search `/nix/store` or the filesystem root. Keep cross-repository durable references canonical. No dependency bounds or pins change under this plan; if one becomes necessary, first verify the released registry version and upstream tags. Implementation commits use Conventional Commits and include this file's `ExecPlan:` trailer, `MasterPlan: docs/masterplans/2-fix-code-and-api-audit-findings.md`, and `Intention: intention_01m58e4vxke9stryg9na9xc9em`.
