---
id: 9
slug: honor-explicit-postgresql-connection-targets
title: "Honor explicit PostgreSQL connection targets"
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

# Honor explicit PostgreSQL connection targets


This ExecPlan is a living document. Update milestone evidence, material discoveries, decisions, and outcomes during implementation. Promote durable decisions into the relevant local ADRs before completion.


## Purpose / Big Picture


Fix audit finding F3 (P1): native operations must connect to the explicitly supplied Unix socket or TCP target even when the parent environment contains conflicting libpq routing defaults. A configured missing socket must fail rather than reaching another server. Preserve credential redaction and the existing public endpoint model.


## Progress


- [ ] M1: Native and rendered connection targets resist ambient endpoint overrides in isolated process tests.
- [ ] M2: Direct loads and owned lifecycle operations honor socket/TCP selection with conflicting environment defaults.

Implementation has not started. The audit observations below describe the original defect, not acceptance of a fix.


## Surprises & Discoveries


None recorded during implementation yet.


## Decision Log


2026-10-18: Enforce routing per connection rather than by process-global environment changes. Retain authentication/TLS behavior except where it can override explicit endpoint selection, keeping this fix within the demonstrated defect.


## Outcomes & Retrospective


Pending implementation and acceptance evidence.


## Context and Orientation


`hinagata-core/src/Hinagata/Connection.hs` owns validated `ConnectionTarget` and `renderConnectionString`. `hinagata-postgres/src/Hinagata/Postgres/Internal/Libpq.hs` passes the rendered text to `PQ.connectStart`. `hinagata-cli/src/Hinagata/Cli/Process.hs` strips ambient PG variables for child commands, but that does not protect native library connections. Core renderer tests are in `hinagata-core/test/Main.hs`; native and CLI integration tests are in `hinagata-postgres/test/Main.hs` and `scripts/test-cli-postgres.sh`.

The audit configured a nonexistent socket directory, set `PGHOSTADDR=127.0.0.1`, and observed a successful fixture load through a loopback TCP proxy at the configured port. Thus a diagnostic naming the socket does not prove the native transport selected it.

[ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md) requires explicit role/endpoint selection without administrative fallback. [ADR 2](../adr/2-stream-fixtures-through-private-postgresql-sessions.md) keeps libpq private and public endpoints driver-independent. These decisions govern this repair; no external architecture decisions are needed.

The working directory for this plan is the Hinagata repository root, `/Users/shinzui/Keikaku/bokuno/hinagata` in the authoring checkout. `hinagata-core` compiles fixture directories into captured plans; `hinagata-postgres` loads them and manages owned database clones; `hinagata-cli` adapts these libraries to commands. A baseline is a sealed template database. A lease is exclusive use of a clone with recorded cleanup responsibility. SQLSTATE is PostgreSQL's five-character error code and does not contain row values.


## Plan of Work


M1 first inspects the installed binding's available connection APIs and upstream libpq option/default processing. Verify how an explicitly empty `hostaddr` interacts with environment and service-file defaults before relying on it. Prefer explicit connection options that prevent an ambient address overriding `host`; put the guarantee in the rendering/native adapter boundary so public rendered strings and internal calls agree. Do not temporarily unset environment variables in the Haskell process: concurrent callers must not observe global mutations. Cover `PGHOSTADDR` directly and a temporary `PGSERVICE`/`PGSERVICEFILE` that supplies conflicting routing options, as well as conflicting PGHOST, PGPORT, PGUSER, and PGDATABASE. Keep explicitly provided fields authoritative. If existing APIs cannot enforce this, a private adapter extension belongs to this plan, with an early native proof before extending all call sites.

This plan changes endpoint routing, not the full TLS or authentication feature set. Preserve currently supported password/passfile and TLS defaults unless they can replace explicit endpoint fields; document that distinction. Explicit credentials remain redacted. Do not promise that every libpq option is independent of the environment.

M2 proves a valid socket target still works with a conflicting address and a nonexistent socket still fails even when a reachable TCP server has matching user/database names. Verify explicit TCP remains TCP, including authentication against a disposable server when configured. Exercise public `withSession`/`loadInto` plus a baseline/clone cycle so all native connections use the same policy. Use subprocess-scoped environments and temporary service files instead of changing the test runner's environment around concurrent tests. Add the endpoint guarantee to `docs/user/configuration.md` and relevant Haddock, and record the durable routing decision in ADR 1 or 2.


## Concrete Steps


Run these commands from the repository root in its development environment (`nix develop` if the tools are not already available). First add the stated failing regressions, then implement the fix and rerun the relevant commands. Do not use a caller-owned database for these tests; leave `HINAGATA_TEST_PGHOST` unset so the scripts create disposable clusters.

```bash
cabal test hinagata-core-test --test-show-details=direct
bash scripts/test-postgres.sh
bash scripts/test-postgres.sh --tcp
cabal build exe:hinagata
bash scripts/test-postgres.sh --cli
```

Cabal tests must finish with `PASS`; shell integration scripts must exit zero and print their final passed message. Record the regression names and concise actual outcomes in this plan when accepted. Existing tests passing without the new reproductions is insufficient.


## Validation and Acceptance


A socket configuration with a conflicting PGHOSTADDR reaches only its socket server. A nonexistent socket must fail while the alternate TCP server records zero fixture writes; use a sentinel table on that server to detect accidental dispatch. A service file cannot inject an address that redirects an explicitly supplied host. TCP tests prove the selected host/port and database are used. Parent environment values remain byte-for-byte unchanged, including when two target-specific child processes run concurrently. Existing quote/backslash credential escaping and redacted Show/error output remain intact. Run a representative native connection before expanding to the lifecycle tests.


## Idempotence and Recovery


The tests must be repeatable with fresh temporary fixture directories, unique database/catalog identities, and cleanup installed before starting servers or workers. Every intentionally blocked operation needs a separate controlling connection or test signal, a bounded wait, and teardown even after assertion failure. Release only resources the test created. Never remove unrelated databases or use a name alone as deletion authority. If interrupted, stop only the test's disposable cluster, inspect its logs, and rerun. Do not delete or rewrite existing user changes. No package publication, release metadata, or dependency upgrades are required.


## Interfaces and Dependencies


No hard prerequisite. Soft ordering: complete `docs/plans/8-preserve-fixture-atomicity-across-sql-whitespace.md` first to close the highest-priority transaction escape. This plan owns `ConnectionTarget` rendering semantics and the options passed to libpq. `docs/plans/10-propagate-cancellation-through-commands-and-resource-lifetimes.md` owns acquisition masking and cleanup in the same native module; it must preserve this plan's option policy. This is an integration relationship, not a whole-plan prerequisite. Default execution is serial to avoid overlapping edits. Authentication capabilities and public driver-specific knobs are outside scope.

Use `mori registry search <dependency>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>` before selecting dependency APIs. Read located source; if the registry has no source, consult authoritative upstream documentation and record the gap. Do not search `/nix/store` or the filesystem root. Keep cross-repository durable references canonical. No dependency bounds or pins change under this plan; if one becomes necessary, first verify the released registry version and upstream tags. Implementation commits use Conventional Commits and include this file's `ExecPlan:` trailer, `MasterPlan: docs/masterplans/2-fix-code-and-api-audit-findings.md`, and `Intention: intention_01m58e4vxke9stryg9na9xc9em`.
