---
id: 6
slug: expose-clone-preparation-hooks-through-the-cli
title: "Expose clone preparation hooks through the CLI"
kind: exec-plan
created_at: 2026-10-18T18:27:51Z
intention: "intention_01m5848c4yegya3azkxwax77c7"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-18T18:27:51Z
---

# Expose clone preparation hooks through the CLI

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Promote durable architectural decisions into the existing ADRs when they change.


## Purpose / Big Picture


A CLI user will be able to configure a service-owned executable that seeds each fresh PostgreSQL clone through real domain commands before scenario fixtures load and before the application starts. This implements [IR-1: Expose clone preparation hooks through the CLI](../improvement-requests/expose-clone-preparation-hooks-through-the-cli.md), including its unchanged AC-1 through AC-5 acceptance criteria. The observable example is a counter created through the service's command API during clone preparation and subsequently read over HTTP after service startup.

The hook must execute once per clone, including clones of a reused baseline. Selecting a different seed executable or arguments must leave an unchanged baseline reusable. Hook failure, timeout, or cancellation must prevent application startup. If a seed process cannot be proven stopped, preserve the database for inspection rather than release it underneath that process.


## Progress


- [ ] Milestone 1: Optional clone-preparation configuration resolves through existing CLI sources, rejects invalid settings, redacts secrets, and preserves configurations that omit it (AC-1).
- [ ] Milestone 2: Native CLI acquisitions execute the selected command once before scenario loading and handoff, reuse unchanged baselines, and handle failure, cancellation, timeout, and uncertain cleanup safely (AC-2, AC-3, AC-4).
- [ ] Milestone 3: The Keiro/workbench example seeds event-backed state through public command/store APIs and observes it through HTTP in independent clones (AC-5).
- [ ] Milestone 4: User documentation, ADRs, package archives, and final regression evidence describe and verify the delivered behavior; IR-1 is completed only after all five criteria pass.

Implementation has not started. The request is accepted and linked to this plan; acceptance criteria remain unverified.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-10-18: Use the configuration prefix `clone.preparation`, with no revision setting. Clone preparation changes disposable clone state, so it must not contribute to baseline fingerprints or require a migration/verification revision. Migration and verification revision behavior remains authoritative for baseline reuse.

2026-10-18: Preserve the existing `BaselineSpec.clonePreparationHook` callback signature. Use its existing lifecycle position; add only the typed failure/cleanup information needed to adapt supervised commands safely. Direct Haskell hooks that return `Left Text` retain their existing generic, credential-safe failure behavior.

2026-10-18: Extend the existing Keiro counter example rather than introduce a new service or require projection workers. Its command and stream-read helpers already use public runtime APIs. PostgreSQL startup, service startup, readiness, and any future projection workers stay caller-owned.

2026-10-18: IR-1 moves from `proposed` to `accepted` when this plan is created. The pinned request profile has no `planned` state. Move it to `in-progress` when implementation starts and to `completed` only with acceptance evidence.


## Outcomes & Retrospective


(To be filled during implementation and after acceptance.)


## Context and Orientation


A baseline is a migrated, verified database sealed against ordinary connections and reused as a PostgreSQL template. A clone is an isolated database copied from that template. A lease records ownership and determines release or preservation. Scenario suffix means only the scenario fixture steps that are not already present in the baseline's verified fixture prefix.

`hinagata-postgres/src/Hinagata/Postgres/Baseline.hs` defines `BaselineSpec`, `ensureBaseline`, and the baseline fingerprint. Its optional `clonePreparationHook` already has type `Maybe (ConnectionTarget -> IO (Either Text ()))`. `hinagata-postgres/src/Hinagata/Postgres/Internal/BaselineRef.hs` stores the selected callback on the in-memory baseline reference; it is excluded from reference identity and fingerprinting. Both a newly built and a reused baseline receive the callback selected for that ensure call.

`hinagata-postgres/src/Hinagata/Postgres/Lease.hs`, in `prepareClone`, already applies clone access, invokes the setup-role hook, loads the scenario suffix, then supplies application access. The acquisition deadline encloses preparation. The current hook boundary discards `Left` details and returns `clone preparation hook failed`. Setup failure and setup exceptions attempt release regardless of callback retention policy. This means merely wiring a subprocess into the existing hook would lose timeout/cancellation diagnostics and could attempt database release even when subprocess cleanup is uncertain. Address those boundaries in Milestone 2.

`hinagata-cli/src/Hinagata/Cli/Config.hs` declares migration and verification `HookSettings` through Settei and resolves YAML, explicit environment bindings, and repeated `--set` overrides. It currently has no clone-preparation declaration. `hinagata-cli/src/Hinagata/Cli/Command.hs` adapts those settings with `hookRunner`, but `prepareBaseline` always sets `clonePreparationHook = Nothing`. `hinagata-cli/src/Hinagata/Cli/Process.hs` supplies shell-free process execution, a setup/application endpoint overlay, a private password file, signal forwarding, and bounded process-group cleanup. Its current hook adapter checks cleanup failure, timeout, and exit status but does not check `cancelledBy` before accepting a zero exit status. Its asynchronous-exception cleanup path also discards `stopGroup`'s uncertain-cleanup result. These paths require explicit coverage for the new hook.

`hinagata-cli/app/Main.hs` acquires clones for `db acquire`, `db with`, and `fixture validate`; `db prepare` only prepares the baseline. `fixture plan` is offline and `fixture load` targets a caller-owned existing database. `hinagata-cli/src/Hinagata/Cli/Output.hs` owns versioned JSON and text reports. All clone-acquiring commands must get the hook through the common baseline assembly, without duplicating seeding in command dispatch.

`scripts/test-cli.sh` tests the CLI offline; `scripts/test-cli-postgres.sh` tests it against PostgreSQL supplied by `scripts/test-postgres.sh --cli`. `hinagata-postgres/test/Main.hs` already checks two legacy hook executions, unchanged baseline reuse, and no callback after a failed hook. Extend those tests where lifecycle behavior changes. `justfile` exposes the validation commands below.

`examples/keiro-service/service/Counter.hs` provides `addCounter`, which calls public `runCommand`, and `counterTotal`, which reads the public event store. `examples/keiro-service/service/Main.hs` exposes counter HTTP routes. The example package manifest, YAML, workbench manifest, Hurl files, and `scripts/example-keiro.sh` together exercise real migration, clone, application-role handoff, readiness, and cleanup.

Relevant decisions are [ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md) and [ADR 3](../adr/3-sealed-baselines-and-positive-database-ownership.md). ADR 1 assigns service migrations, domain APIs, PostgreSQL startup, and HTTP orchestration to their owners; it requires setup/application credential separation and process cleanup before release. ADR 3 specifies per-clone preparation before scenario loading, exclusion from the sealed-template fingerprint, and positive ownership checks before deletion. Preserve those decisions and amend them for the CLI failure contract. The ADR corpus uses ordinary Markdown, with no profiled ADR bundle in `mori.dhall`.

The upstream adoption context is `mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract`. This plan implements the local request independently; it is not a child of that external MasterPlan and does not claim its adoption complete. IR-2 content-derived baseline revisions and IR-3 Linux CI evidence are separate requests.


## Plan of Work


### Milestone 1: Declare the optional command contract


In `hinagata-cli/src/Hinagata/Cli/Config.hs`, add clone-preparation settings for `clone.preparation.executable`, `.argv`, `.cwd`, `.environment`, and `.deadline_ms`. Reuse declaration/validation helpers where suitable, but separate command settings from baseline-only `revision`. Do not declare a clone-preparation revision or copy it into migration or verification revisions. Use a positive default deadline of 300000 milliseconds, matching existing hook defaults; document that the remaining acquisition deadline can end setup sooner.

Absence of an executable, empty argv/environment, and no cwd means no hook. Reject nonempty command settings without an executable; an explicit deadline alone may remain harmless, consistent with existing hooks. Validate executable and argument NULs, absolute cwd, positive deadline, and `NAME=VALUE` overlays before database work. Reserve `PG*` and `HINAGATA_*` overlays exactly as `parseOverlay` does today. Arguments and environment values remain secret in schema/explanation output. Generalize the existing misleading template-specific executable description so descriptions distinguish baseline and clone execution.

Bind scalar values to `HINAGATA_CLONE_PREPARATION_EXECUTABLE`, `HINAGATA_CLONE_PREPARATION_CWD`, and `HINAGATA_CLONE_PREPARATION_DEADLINE_MS`. As with existing hooks, arrays come from YAML rather than invented environment splitting. Resolve the same YAML → environment → repeated override precedence. Ensure `--check-config` rejects invalid hook combinations offline; currently some hook validation only occurs inside `prepareBaseline`, so factor shared semantic validation into configuration checking as needed without connecting or executing commands.

Extend `scripts/test-cli.sh` with schema, original-config, valid YAML argv/environment, scalar override/precedence, malformed settings, and secret-sentinel checks. Include arguments containing spaces and shell syntax to prove they remain literal. No new CLI subcommand is needed. Acceptance is a passing offline gate with no PostgreSQL connection or seed invocation.


### Milestone 2: Wire acquisition and preserve process safety


In `hinagata-cli/src/Hinagata/Cli/Command.hs`, build an optional command callback and set `BaselineSpec.clonePreparationHook` to it. Omitted configuration must produce `Nothing`, and configured callbacks must use `runChild` with the supplied setup target. Do not execute the callback during baseline preparation. Do not add clone settings to `fingerprintManifest`, alter catalog format, or cache a callback from an earlier CLI configuration.

First prove a representative producer/consumer path in `scripts/test-cli-postgres.sh`: a command helper inserts a clone-specific probe, scenario SQL depends on that probe, and the consumer reads the result. Run two leases and show different database identities and one hook invocation per lease. Re-run `db prepare` with different preparation argv and then acquire again: preparation must report `Reused` with the original fingerprint, and the next clone must contain the new seed. Also select a different executable, remove the hook, and exercise a reused baseline. Check baseline invariance through unchanged generation identity and an unhooked clone's state; do not unseal a template just to inspect it. `db prepare`, offline planning, and direct fixture loading must never invoke the hook.

Introduce a narrowly scoped typed command-hook failure contract in `hinagata-postgres/src/Hinagata/Postgres/Lease.hs` (or a dedicated exposed module if separating the types avoids module cycles). Keep the legacy callback type intact: the CLI adapter raises the typed failure for supervised-process outcomes, and the library catches it specifically at the preparation boundary. The failure distinguishes spawn/identity failure, nonzero exit, timeout, cancellation, and uncertain process cleanup, and separately records whether release is safe. Only fixed safe reasons, numeric statuses/signals, and generated ownership identifiers cross this contract. Do not forward arbitrary hook-returned text, child output, argv, environment, connection strings, or raw exception messages into reports.

Extend `LeaseError` with optional structured preparation context containing the failure category and available run/lease identifiers, updating all local constructors and patterns. Populate identifiers from the allocated clone; the callback need not acquire a new context argument or receive administration access. Keep unrelated errors unchanged and provide a common CLI mapping used by `db acquire`, `db with`, and each `fixture validate` result. Preparation failures use phase `clone-preparation` and stable codes `clone_preparation_failed`, `clone_preparation_timeout`, `clone_preparation_cancelled`, or `clone_preparation_cleanup_failed`. Add optional identifiers to error JSON without changing `formatVersion: 1` or existing success fields.

Check `ChildReport.cancelledBy` before accepting an otherwise successful hook exit. Hook cancellation must remain a failure even if a signal handler exits zero. For CLI SIGINT/SIGTERM, return 130/143 after cleanup, including preparation-phase cancellation before the application starts. Nonzero seed exits and spawn errors are operational failures (exit 1), rather than application child exit statuses. A hook deadline and the enclosing acquisition deadline must both prevent startup; annotate an acquisition timeout with the preparation phase when it expires inside this hook rather than scenario loading.

In `hinagata-cli/src/Hinagata/Cli/Process.hs`, ensure timeout and exception unwinding perform bounded process-group cleanup and retain its result. An uncertain stop during asynchronous unwinding must be reported through a typed cleanup exception rather than discarded or swallowed by the enclosing acquisition timeout. Translate that into the typed preparation failure before the library's generic exception/release branch. Update the existing application-command caller for any generic process exception added, preserving its existing retention behavior. Keep cancellation semantics for unrelated exceptions and do not use an unbounded uninterruptible wait.

When stopping processes is proven, preparation failures release using existing ownership checks. When it is uncertain, mark the clone preserved with a bounded non-secret diagnostic, or leave an inspectable orphan if the ownership session has been lost; do not call database drop in that branch. Keep cleanup failure distinct from the primary preparation failure. `--preserve-on-failure` continues to describe consumer failures; an ordinary seed failure still releases, while uncertain seed-process cleanup requires preservation regardless of that flag.

Prove failure, both deadline sources, SIGINT/SIGTERM, cancellation with a zero child exit, descendants that ignore TERM, and exception unwinding. Use a consumer startup marker and assert it never appears after failed preparation. Add deterministic fault injection at the process cleanup boundary for the rare uncertain-stop branch; a stubborn child killed successfully only proves successful escalation. Use an internal test seam or focused test component, never a public environment/configuration bypass. Assert bounded completion, stopped descendants where stoppage is provable, removed password files, secret-free structured errors, and an inspectable retained ownership record when stopping or release cannot safely complete. Add a real blocked-drop case using the existing PostgreSQL cleanup-test pattern. Keep existing direct-library hook tests passing.


### Milestone 3: Demonstrate a service-owned command seed over HTTP


Add `examples/keiro-service/seed/Main.hs` and an executable `hinagata-keiro-seed` to `examples/keiro-service/hinagata-keiro-example.cabal`. Share `Counter` from `examples/keiro-service/service/Counter.hs` between the service and seed executable through declared source directories or a small package-internal common component. The seed accepts a counter ID and positive increment count, obtains its connection from the managed PG variables, opens the public store with the existing connection-settings pattern, invokes `addCounter` the requested number of times, and closes the store before exiting. It must honor optional `PGPASSFILE` authentication and fail nonzero on any rejected/failed command. No HTTP server is required during seeding.

Configure the seed in `examples/keiro-service/hinagata.yaml`; supply its machine-specific executable path from `scripts/example-keiro.sh`. Add `examples/keiro-service/hurl/counter-seeded.hurl` and a workbench read-only recipe/suite in `examples/keiro-service/hurl-workbench.dhall`. The request `GET /counters/seeded` must return 200, JSON media type, and the expected total created before startup. Supply the expected total as an explicit workbench parameter if the driver varies it. Keep the existing opt-in mutating counter suite independent by using a different counter ID.

Run two independent leases with distinct seed totals against the same unchanged baseline. Read each total over HTTP, verify separate lease IDs, verify baseline reuse after changing preparation arguments, and verify released ownership records and stopped service processes. Retain existing concurrent reference-data, application-role permission, readiness-failure, and cancellation checks. Fixture SQL may still create independent reference data but must not fabricate event, outbox, or workflow rows. The existing workbench process continues to own service readiness and shutdown.

Register the new Hurl file in `justfile`'s formatting check and the package's `extra-source-files`; package the seed source and shared module through normal Cabal source declarations. Extend `scripts/release-check.sh` to check the new source/archive artifacts. `nix develop -c just example-keiro` is the acceptance command for this milestone.


### Milestone 4: Document the contract and close with evidence


Update `docs/user/configuration.md`, `docs/user/cli.md`, `docs/guides/integrate-service.md`, `docs/cli.md`, and `examples/keiro-service/README.md`. Explain the order baseline → clone/access → preparation command → scenario suffix → application handoff. Include runnable YAML, environment bindings, omission behavior, effective deadlines, failure phases, credential handling, and the difference between baseline data, per-clone domain seeds, and scenario fixtures. State which commands invoke the hook and that changing it does not invalidate the baseline. Update generated timestamps and bundle logs for changed profiled documentation. Amend ADR 1 and ADR 3 for the durable command/preparation cleanup boundary.

Run the final checks below once on the final candidate, recording concise results against AC-1 through AC-5. Keep implementation discoveries and accepted design changes in this plan. Move IR-1 to `in-progress` with an updated generated timestamp and bundle log at implementation start. Only after acceptance passes, set `status: completed`, add `completedAt` and a concise evidence-bearing `resolution`, and retain `targetPlan`. Preserve existing review provenance; do not describe the author assessment as independent implementation approval. Validate the request bundle after lifecycle metadata changes. Do not mark IR-2, IR-3, or the external adoption MasterPlan complete.


## Concrete Steps


Run all commands from the repository root. The development shell supplies Cabal/GHC, PostgreSQL tools, Hurl, Dhall, OKF, and Just. The integration wrapper creates a disposable local cluster when no explicit test endpoint is supplied. Leave external `HINAGATA_TEST_PG*` endpoint variables unset for these commands.

For Milestone 1:

```bash
nix develop -c just test-cli
```

Expected result: the offline smoke script exits zero and prints `CLI offline smoke test passed`, including new configuration assertions. A configured seed marker remains absent throughout offline diagnostics.

For Milestone 2, build and use the existing disposable PostgreSQL wrappers:

```bash
nix develop -c just test-cli-postgres
nix develop -c just test-postgres
```

Expected result: CLI integration exits zero, and the PostgreSQL test suite passes legacy and extended lifecycle cases. Capture specific evidence for ordering, callback replacement, timeout/cancellation, and preserved uncertain-cleanup state rather than treating compilation as acceptance.

For Milestone 3:

```bash
nix develop -c just example-keiro
```

Expected result: the new pre-seeded counter read and existing example suites pass; every successfully released suite has no remaining service process or owned database. Two selected seed totals are read from separate clones while baseline preparation remains `Reused`.

A configuration fragment to document and exercise, layered over a complete existing configuration, is:

```yaml
clone:
  preparation:
    executable: /absolute/path/to/hinagata-keiro-seed
    argv: [seeded, "2"]
    cwd: /absolute/path/to/service-workspace
    environment: []
    deadline_ms: "10000"
```

For final verification, reuse passing results from the same final candidate rather than repeating unchanged slow suites. Add the remaining regression and archive checks:

```bash
nix develop -c just core-test
nix develop -c just example-workbench
nix develop -c just check-conventions
nix develop -c just check-docs
nix develop -c just fmt-check
nix develop -c just release-check
```

After request-only metadata edits, the focused failing gate is:

```bash
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

Commits made during implementation use Conventional Commits and include both `ExecPlan: docs/plans/6-expose-clone-preparation-hooks-through-the-cli.md` and the `Intention:` trailer from this plan's frontmatter. Work on the current branch unless the user asks otherwise.


## Validation and Acceptance


AC-1 is proved by offline parser/configuration assertions for all five command settings, source precedence, invalid values, redaction, and an original configuration with no hook. This must not invoke a seed or open PostgreSQL.

AC-2 is proved by two fresh leases with distinct database identities, one recorded helper invocation each, a scenario SQL dependency on the seed, and consumer reads after preparation. Baseline-only preparation and an unhooked clone prove the template was not seeded. Run the hook for `db acquire`, `db with`, and scenario validation, including concurrent validation so shared mutable failure state cannot leak across leases.

AC-3 is proved by preparing a baseline, reusing it, changing clone executable/argv, preparing again, and reading the newly selected seed from the next clone. The report stays `Reused`, the fingerprint and generation remain unchanged, and removing the hook restores unseeded clones. Missing migration/verification revisions must still disable baseline reuse as before.

AC-4 is proved by real subprocess failure, spawn failure, deadline expiry at each boundary, and signal cancellation before startup; by zero consumer-start markers; by bounded descendant cleanup and private-password-file removal; and by deterministic uncertain-cleanup injection plus real database release failure. Inspect the retained/orphaned ownership record and bounded diagnostic. Verify credentials and secret sentinels are absent from configuration explanations and structured reports. Arbitrary user executable output remains the executable author's responsibility and is sent to stderr, never embedded in JSON errors.

AC-5 is proved by the packaged Keiro seed calling existing public command/store helpers and a later HTTP GET observing the expected event-backed counter value under the application role. Two distinct seed selections use independent clones of the same baseline. No fixture inserts runtime event/outbox/workflow rows. Source-archive builds include the seed executable, shared module, manifest, and Hurl file.

The first representative interaction proof is the command-backed native PostgreSQL lease in Milestone 2, before adding HTTP variations. No dependency upgrade, broader orchestration feature, performance target, or new Linux-support claim is required for acceptance.


## Idempotence and Recovery


Each test run uses fresh temporary fixture/bundle directories and a disposable PostgreSQL cluster. Seeds execute once per newly created clone, so they may assume that clone's initial baseline state; they need not survive arbitrary retries on the same database. Do not retry failed preparation automatically. Existing retained leases must be inspected and explicitly released through the ownership-checked CLI, never by guessing database names or dropping matching prefixes.

A preparation timeout includes process shutdown before safe database release. If shutdown is uncertain, retain the clone and remove only the private local password file after the bounded supervisor has unwound. Retention does not prove a child stopped; an operator must establish that before explicit release. If catalog ownership is lost, preserve inspectable allocation evidence and follow existing orphan recovery. Do not change catalog schema or baseline identity as part of this work.

Configuration changes apply to future acquisitions through the next prepared in-memory handle; they do not mutate already issued library handles or running leases. Repeating `db prepare` with truthful baseline revisions is safe and does not seed the sealed database. Disabling the new optional settings restores the original behavior. Record partial milestone state and the failing acceptance case here if implementation is interrupted.


## Interfaces and Dependencies


The durable CLI interface is the optional `clone.preparation` configuration record described above. The library callback stays `ConnectionTarget -> IO (Either Text ())`, and the target is the clone's setup endpoint. The CLI's supervised adapter uses typed failures to preserve machine-readable outcomes and release safety; legacy hooks retain their ordinary `Left` and exception behavior. Additive error context includes generated lease/run IDs when allocation has occurred, not credentials. Keep failure classification per acquisition, avoiding global state that would race under concurrent fixture validation.

Use existing `ChildSpec`/`ChildReport` and process-group supervision; do not introduce shell parsing or a second process runner. A typed uncertain-cleanup exception must survive asynchronous unwinding long enough for `Lease.hs` to select preservation. Existing consumer-command retention and cancellation behavior is part of the regression contract. Add a focused internal test component in `hinagata-cli/hinagata-cli.cabal` only if needed for deterministic cleanup fault injection.

No new external dependency or version change is planned. Configuration uses `mori://shinzui/settei/packages/settei`, `mori://shinzui/settei/packages/settei-env`, and the existing YAML/optparse adapters. Domain commands use `mori://shinzui/keiro/packages/keiro`; workbench remains `mori://shinzui/hurl-workbench` at the example's existing immutable revision. Discover dependency sources and documentation with `mori registry search`, `mori registry show --full`, and `mori registry docs` before relying on their APIs. If implementation requires changing dependency bounds or pins, verify current authoritative registry releases and upstream tags first. Never traverse `/nix/store` for source.

This plan has no parent MasterPlan and no prerequisite implementation plan. Existing completed lifecycle and CLI behavior in the working tree supplies the starting point. IR-1 retains its stable acceptance conditions and its `targetPlan` reference throughout implementation and completion.
