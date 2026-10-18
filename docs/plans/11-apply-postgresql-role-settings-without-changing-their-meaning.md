---
id: 11
slug: apply-postgresql-role-settings-without-changing-their-meaning
title: "Apply PostgreSQL role settings without changing their meaning"
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

# Apply PostgreSQL role settings without changing their meaning


This ExecPlan is a living document. Update milestone evidence, material discoveries, decisions, and outcomes during implementation. Promote durable decisions into the relevant local ADRs before completion.


## Purpose / Big Picture


Fix audit finding F6 (P2): a configured search_path containing multiple schemas must be stored and applied as that schema list. Preserve scalar and custom settings, role-owned permissions, and safe SQL construction. Baselines created under the buggy setting interpretation must not be silently reused after the fix.


## Progress


- [ ] M1: Setup/application role settings retain PostgreSQL semantics and apply under the existing role permissions.
- [ ] M2: Correct settings are observed in migrations and clones, and old-semantics baselines are excluded from reuse.

Implementation has not started. The audit observations below describe the original defect, not acceptance of a fix.


## Surprises & Discoveries


None recorded during implementation yet.


## Decision Log


2026-10-18: Version the baseline fingerprint with the semantics repair. Otherwise unchanged declarations could select a sealed database prepared under the previous, incorrect search_path interpretation. Use server interpretation rather than ad hoc list parsing.


## Outcomes & Retrospective


Pending implementation and acceptance evidence.


## Context and Orientation


`hinagata-core/src/Hinagata/Config.hs` exposes RoleSetting with a validated identifier name and Text value; settings accept NAME=VALUE entries, including a YAML array for values containing commas. `hinagata-postgres/src/Hinagata/Postgres/Internal/Access.hs` applies each through ALTER ROLE ... IN DATABASE ... SET followed by one quoted literal. PostgreSQL interprets the literal for search_path as one schema item. The audit accepted `setup.settings: ["search_path=public,pg_catalog"]`, reported Built, and recorded `search_path="public,pg_catalog"` in pg_db_role_setting.

`hinagata-postgres/src/Hinagata/Postgres/Baseline.hs` hashes settings into `fingerprintManifest`, compares manifests in `comparePrevious`, and reuses matching Ready generations. A fingerprint is the identity of state-affecting inputs. Keeping the same fingerprint after changing how those inputs are interpreted can reuse the wrong database. `hinagata-postgres/test/Main.hs` already tests independent roles, settings-before-migration, fingerprint comparison, and credential rotation.

[ADR 3](../adr/3-sealed-baselines-and-positive-database-ownership.md) requires each role to apply its own settings through a short-lived connection, avoiding a CREATEROLE requirement on the database owner. It also requires correct fingerprint invalidation and non-secret comparison categories. Preserve those constraints.

The working directory for this plan is the Hinagata repository root, `/Users/shinzui/Keikaku/bokuno/hinagata` in the authoring checkout. `hinagata-core` compiles fixture directories into captured plans; `hinagata-postgres` loads them and manages owned database clones; `hinagata-cli` adapts these libraries to commands. A baseline is a sealed template database. A lease is exclusive use of a clone with recorded cleanup responsibility. SQLSTATE is PostgreSQL's five-character error code and does not contain row values.


## Plan of Work


M1 keeps the existing Text-based public configuration contract initially and uses PostgreSQL to interpret parameterized setting values rather than splitting commas or accepting raw SQL. Prove the representative path first: on a role-owned temporary session, use a transaction, `pg_catalog.set_config` with parameters for name/value, and ALTER ROLE ... IN DATABASE ... SET the quoted name FROM CURRENT. Temporary session/local state must not leak beyond the dedicated session, and failure must roll back the persistent change. Verify FROM CURRENT preserves quoted schema names, the $user token, and lists before applying this strategy to every setting. Check a scalar such as client_min_messages, a custom dotted setting, and default_transaction_read_only: avoid making the persistence statement run in a newly read-only transaction. Choose transaction boundaries and local state accordingly. No input may be concatenated as executable value SQL. If upstream rules prevent this approach for an otherwise previously supported setting, document the concrete case and refine the persistence helper before declaring M1 complete; do not silently narrow the supported settings.

M2 exercises the public baseline/lease API with separate admin, setup, and application roles. A migration must observe the declared multi-schema path and successfully resolve a table in its expected schema; a clone application connection must observe its own path. Verify custom/scalar values and quoted/comma-containing schema names using server reads and actual relation lookup, not only generated SQL strings.

Change the fingerprint format marker to `hinagata-fingerprint-v2` for the corrected semantics so pre-fix generations cannot match the new digest. Keep the same component ordering where possible and teach comparison to accept supported v1 and v2 manifests, reporting FingerprintVersion plus any real input changes. Do not migrate, mutate, or delete an existing sealed baseline or change catalog format for this. Add a legacy-generation fixture with the old manifest/digest and prove it remains inspectable but is not reused; a subsequent call with the new version must reuse the correctly built generation. Update the fingerprint documentation and ADR 3. This is runtime cache identity work, not a package version or release task.


## Concrete Steps


Run these commands from the repository root in its development environment (`nix develop` if the tools are not already available). First add the stated failing regressions, then implement the fix and rerun the relevant commands. Do not use a caller-owned database for these tests; leave `HINAGATA_TEST_PGHOST` unset so the scripts create disposable clusters.

```bash
cabal test hinagata-core-test --test-show-details=direct
bash scripts/test-postgres.sh
cabal build exe:hinagata
bash scripts/test-postgres.sh --cli
```

Cabal tests must finish with `PASS`; shell integration scripts must exit zero and print their final passed message. Record the regression names and concise actual outcomes in this plan when accepted. Existing tests passing without the new reproductions is insufficient.


## Validation and Acceptance


The YAML array entry `search_path=public,pg_catalog` results in two schemas rather than one quoted comma-containing name. A deliberately quoted single schema containing a comma remains one schema. Apostrophes, backslashes, $user, and custom dotted parameter names preserve their intended values without executing injected statements. Scalar settings continue working. An ordinary application role can apply its own allowed settings without granting extra cluster-wide privileges to the administration role. Test failures leave no half-persisted role-setting transaction.

A baseline produced with the previous fingerprint format is not reused for the corrected semantics; the next identical corrected preparation is Reused. An explicitly selected old reference produces a usable comparison identifying FingerprintVersion, not an unsupported-manifest error. Raw setting values and credentials stay out of the stored non-secret fingerprint comparison output. Clone acquisition observes the corrected values independently of whether its baseline was just built or reused.


## Idempotence and Recovery


The tests must be repeatable with fresh temporary fixture directories, unique database/catalog identities, and cleanup installed before starting servers or workers. Every intentionally blocked operation needs a separate controlling connection or test signal, a bounded wait, and teardown even after assertion failure. Release only resources the test created. Never remove unrelated databases or use a name alone as deletion authority. If interrupted, stop only the test's disposable cluster, inspect its logs, and rerun. Do not delete or rewrite existing user changes. No package publication, release metadata, or dependency upgrades are required.


## Interfaces and Dependencies


No hard prerequisite. This stream can be implemented independently; default ordering follows cancellation work to avoid simultaneous edits to lifecycle tests. It owns role-setting interpretation, `Access.setRoleSetting`, fingerprint format compatibility in `Baseline`, and corresponding configuration docs. `RoleSetting` source shape should remain unchanged unless the early native proof demonstrates a necessary API change, which must be reflected in this plan and all callers. Integration with `docs/plans/12-preserve-structured-fixture-errors-across-lifecycle-apis.md` concerns BaselineError construction and output; that plan owns error shape, this plan owns semantic identity. Preserve missing-hook-revision reuse rules, credential-rotation behavior, and the existing catalog schema.

Use `mori registry search <dependency>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>` before selecting dependency APIs. Read located source; if the registry has no source, consult authoritative upstream documentation and record the gap. Do not search `/nix/store` or the filesystem root. Keep cross-repository durable references canonical. No dependency bounds or pins change under this plan; if one becomes necessary, first verify the released registry version and upstream tags. Implementation commits use Conventional Commits and include this file's `ExecPlan:` trailer, `MasterPlan: docs/masterplans/2-fix-code-and-api-audit-findings.md`, and `Intention: intention_01m58e4vxke9stryg9na9xc9em`.
