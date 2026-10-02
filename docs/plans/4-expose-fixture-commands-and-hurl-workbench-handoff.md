---
id: 4
slug: expose-fixture-commands-and-hurl-workbench-handoff
title: "Expose fixture commands and hurl-workbench handoff"
kind: exec-plan
created_at: 2026-09-26T23:47:59Z
intention: "intention_01m3g1rc9re2qa1cy17q25qfq8"
master_plan: "docs/masterplans/1-build-hinagata-for-fast-postgresql-fixtures-and-isolated-microservice-tests.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T23:47:59Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T00:16:30Z
      mode: "update"
      note: "Incorporate prior-art source review into contracts and acceptance."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T04:33:49Z
      mode: "update"
      note: "Audit applicable haskell-jitsurei standards and make missing acceptance requirements explicit."
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T00:30:12Z
      mode: "update"
      note: "Fix child env overlay to PG* plus run/lease IDs, PGPASSFILE password channel, explicit child stdin"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-10-02T12:05:37Z
      mode: "implement"
      note: "Begin CLI and process handoff implementation"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T00:27:54Z
      verdict: "changes-requested"
      note: "Env overlay conflicts with spec (HINAGATA_DATABASE); define password channel and child stdin for the process group"
---

# Expose fixture commands and hurl-workbench handoff

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update relevant ADRs when durable decisions change.


## Purpose / Big Picture

Developers can inspect fixture plans, load an existing socket database, validate scenarios, and wrap their normal service test command in an isolated database lease. hurl-workbench receives the database through the service's existing configuration before startup, while retaining ownership of readiness, Hurl execution, and reports.


## Progress

- [ ] Thin CLI exposes Settei diagnostics, fixture planning/loading, and stable JSON errors.
- [ ] Database lifecycle commands and generic command handoff preserve lease/process lifetimes.
- [ ] A runnable hurl-workbench example passes and failure/cancellation leaves the expected resources.

2026-10-02 CLI bootstrap progress: The new `hinagata-cli` package is wired into `cabal.project`, the unmanaged `flake.module.nix`, and `just check`. Its first offline slice uses Settei's strict YAML, environment, and repeated override sources for schema, check, explanation, and `fixture plan` commands. The plan command emits format-version-1 JSON or text without connecting to PostgreSQL; the CLI also provides help, version fallback, and parser-derived shell completion scripts before configuration resolution. `just test-cli` checks absent-file help/schema behavior, nested completion, a no-server plan, and secret redaction on a typed resolution failure. `nix develop -c just check` passes including the new Nix package and source distribution. Loading, validation, database commands, build-revision injection, and workbench handoff remain open.


## Surprises & Discoveries


## Decision Log

2026-09-26: Use a generic executable-plus-argv lease wrapper, not a new Hurl runner or workbench fixture schema. Use Settei's direct YAML adapter and standard diagnostic/exit conventions; expose no shell-evaluated environment output.

2026-09-30: Fix the child environment overlay to exactly `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `HINAGATA_RUN_ID`, and `HINAGATA_LEASE_ID`, dropping the earlier ambiguous `HINAGATA_DATABASE` variable so the spec, MasterPlan, and example wrapper agree. A password, when one exists, travels only through a private `PGPASSFILE`. The child gets an explicit stdin because a background process group reading the terminal is stopped by SIGTTIN.


## Outcomes & Retrospective


## Context and Orientation

Hard dependency: `docs/plans/3-manage-reusable-baselines-and-isolated-database-leases.md` provides lifecycle operations, with loading/core prerequisites transitively complete. Own `hinagata-cli/hinagata-cli.cabal`, `hinagata-cli/app/Main.hs`, `hinagata-cli/src/Hinagata/Cli/{Options,Config,Command,Output,Process}.hs`, CLI tests, `examples/workbench/`, and `docs/cli.md`. The earlier plans own all database behavior.

[ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md) limits the runner boundary; [ADR 3](../adr/3-sealed-baselines-and-positive-database-ownership.md) governs cleanup. `mori://shinzui/settei/okf/adrs/concepts/ADR-2` and `mori://shinzui/keiro-runtime-patterns/docs/config-settei-cli-standard` govern settings. `mori://shinzui/hurl-workbench` has unindexed `docs/adr/6-managed-service-process-group-lifecycle.md` and `docs/reference/workspace.md` (artifact-level URIs pending): suites already own a service and stable environment, with POSIX process-group cleanup. There is no assumed per-case fixture hook.

All paths below are repository-relative and proposed unless explicitly described as existing. At planning time only `docs/initial-spec.md`, project metadata, and planning tools existed. The specification now describes the intended library. Dependency research is in `docs/research/initial-design.md`; discover dependency source with Mori before using APIs, then verify current releases with package registries and upstream tags before selecting bounds. Never search the filesystem root or `/nix/store`.

Follow GHC >=9.12, GHC2024, strict unprefixed records, explicit deriving strategies, postpositive qualified imports, and the project prelude. Keep generic-lens orphan imports out of public type-definition modules and the prelude. These conventions come from `mori://shinzui/haskell-jitsurei/docs/core-standards`, `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`.

Every library, executable, test, and benchmark component imports its package's `common common` baseline with GHC2024 and DeriveAnyClass/DuplicateRecordFields/OverloadedLabels/OverloadedStrings. Use generic-lens labels consistently for record access/updates; construction and constructor-directed patterns are valid. Import `Data.Generics.Labels ()` plainly only where required, and inspect transitive imports so public facades do not leak the orphan. Keep entity IDs first in command/event payloads where applicable. Operators stay unqualified; hide clashing prelude exports.

Use MultilineStrings for suitable embedded multiline text per `mori://shinzui/haskell-jitsurei/docs/core-multiline-strings`, preserving external fixture bytes. The [standards audit](../research/haskell-standards-audit.md) records applicability and acceptance ownership. Expected errors are typed; resource cleanup must run on asynchronous exceptions without swallowing them.


## Plan of Work

### Milestone 1: Fixture CLI and diagnostics

Create optparse commands `fixture plan NAME...`, `fixture load NAME...`, and `fixture validate NAME...|--all`. Direct load requires an explicit target and is documented as a write to a caller-controlled test database. Validation uses isolated clones and tests each selected scenario separately with bounded workers and declaration-order results. Plan does not connect to PostgreSQL. Return versioned JSON containing identifiers, phase, stable error code, fixture/step context, and safe target metadata, with human diagnostics on stderr when JSON is selected.

Compose Settei defaults, explicitly repeated YAML config files, explicit environment bindings, and repeated CLI overrides in that order. Expose schema diagnostics before reading files, and explanation/check diagnostics after resolution but before action. Declare credentials secret at the settings boundary and preserve report redaction. CLI migration/verification hooks become executable+argv, cwd, explicit environment overlay, revision, and deadline; a migration command path alone cannot authorize persistent reuse.

Group connection, fixture, lifecycle, and output options following `mori://shinzui/haskell-jitsurei/docs/cli-option-groups`. Add `completions bash|zsh|fish` derived from the actual parser and `--version` showing package version plus available build revision, following `mori://shinzui/haskell-jitsurei/docs/cli-shell-completions` and `mori://shinzui/haskell-jitsurei/docs/cli-version-git-sha`. Verify current dependency APIs before adopting examples. Help/version/completion must dispatch before operational configuration or PostgreSQL access. Test nested-command completion, shell argument quoting, normal help, and absent-Git version fallback. Wire reproducible revision injection through unmanaged `flake.module.nix`; do not edit generated Seihou files. Centralize JSON options in the core prelude and keep CLI DTO encoders explicit where redaction/versioned fields require it.

### Milestone 2: Lease commands and process handoff

Add `db prepare`, `db acquire`, `db release ID`, `db with --fixture NAME -- PROGRAM ARGS...`, `inspect ID`, and `clean`. `clean` previews; `--apply` revalidates before removal, and retained resources require selection. `db acquire --json` creates a Detached lease and emits safe fields/ID; it does not expose credentials. Every command delegates to the library without implementing SQL or ownership logic. Preparation/inspection JSON includes fingerprint component categories, reuse/build reason, lifecycle state, and phase timings from library reports. Do not emit secrets or raw fixture data. Test first build, warm reuse, fixture/hook/role invalidation, timeout/saturation, and stable error codes. `fixture plan` remains offline and cannot claim that a database cache entry is reusable.

For `db with`, use a scoped library manager and classify child outcomes explicitly. Select only application access for child connection variables; test that administration/setup credentials cannot leak into the overlay or diagnostic reports. Acquire/load before spawning one generic child and overlay exactly `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE` from the application endpoint plus `HINAGATA_RUN_ID` and `HINAGATA_LEASE_ID`; define no other Hinagata variable. No variable ever carries a password: when the application role needs one, write it to a private mode-0600 password file created for this child, point `PGPASSFILE` at it, and remove the file after the child is reaped; with Unix-socket peer authentication no password material exists at all. Do not mutate the parent process environment. Start the wrapper in its own POSIX process group and give it an explicit stdin (`/dev/null`) rather than the terminal, because a background process group that reads the terminal is stopped by SIGTTIN. Forward SIGINT and SIGTERM received by the CLI to that group, terminate descendants with a bounded TERM→KILL escalation, and reap before releasing the lease. A nested workbench process owns its service group; graceful signal handling must get time to finish that cleanup. If descendants cannot be proven stopped, retain the lease and report cleanup failure instead of claiming a clean release. Make process failure, spawn failure, cancellation, and database cleanup failure distinct outcomes.

Preserve exact child exit status when the child fails; report accompanying cleanup failures separately. A successful child followed by cleanup failure exits 1. Settei exit codes remain usage 2, source 3, resolution 4. Support `--preserve-on-failure` with an inspectable ID for child failures. No Hurl-specific syntax or command is added.

### Milestone 3: Working suite handoff

Build `examples/workbench/` with a small database-backed fixture service, fixture sources, a Hinagata YAML configuration, a service wrapper, and an ordinary hurl-workbench manifest/Hurl file. The wrapper maps lease environment to the service's Settei settings. Define the service command/readiness in the existing workbench schema. Pin a verified released tool or documented immutable revision; do not reference a developer's absolute checkout in checked-in files.

Apply `mori://shinzui/haskell-jitsurei/docs/api-hurl-integration-testing` to this example: organize files by resource family; assert status for every request and media type/stable semantics for every body-bearing response; include a relevant negative case. Explicitly list independent default files, keep writes/special configurations opt-in with their prerequisites, and document fixture identities/cardinality and repeatability. Hurl/hurlfmt are reproducible external test tools, not Cabal dependencies. Add `hurlfmt --check`; workbench continues to own readiness, execution, and process cleanup. Demonstrate the service opens the clone and an HTTP assertion sees committed seeded state. Run two isolated suites with distinct ports and leases. A workbench matrix sharing one service is not per-case database isolation; document separate suite invocations for that guarantee. Update README/CLI help with direct socket loading, cleanup, detached resources, and the sample commands. Keep the example's server test-only rather than adding service orchestration to the library.


## Concrete Steps

Run from the Hinagata repository root. The commands below are acceptance interfaces to create in this plan or consume from its prerequisites; they are not claimed to work in the original documentation-only tree.

```bash
nix develop -c cabal run hinagata -- --describe-config-json
nix develop -c cabal run hinagata -- --config examples/workbench/hinagata.yaml --check-config
nix develop -c cabal run hinagata -- --config examples/workbench/hinagata.yaml fixture plan seeded-member --json
nix develop -c just test-cli
nix develop -c just example-workbench
nix develop -c just check
```

Schema/check/plan commands succeed with no PostgreSQL server and perform no mutation. Explain output proves source precedence and redacts a sentinel credential even on invalid input. `just example-workbench` starts one owned test cluster, creates a lease, has workbench start the service and pass its Hurl assertion, stops the service, and releases the lease. An intentionally failing Hurl assertion preserves exact status and, with preservation enabled, leaves an inspectable database. Cancellation after service startup leaves no running process or improperly dropped active database. Detached acquire followed by a separate release works across CLI processes.


## Validation and Acceptance

Acceptance requires the observable results above, passing focused tests, and the repository checks appropriate to the completed components. Record concise evidence here and in Progress; do not report planned commands as executed. Build documentation from the exposed library API and keep examples runnable. Update dependency metadata and check source distributions when adding a package or public module.


## Idempotence and Recovery

Never shell-evaluate emitted JSON or pass secret connection strings in argv. Repeating read-only planning/check modes is safe. Repeating load may conflict by design. Recover retained IDs with inspect and explicit release; keep a failed cleanup record. Example traps stop only their process groups and disposable cluster. No changes to the external workbench repository are required.


## Interfaces and Dependencies

The CLI calls core compilation/configuration and PostgreSQL load/lease APIs. `Cli.Process` owns only the generic child lifecycle, never HTTP readiness or Hurl interpretation. `Cli.Output` owns JSON formatVersion 1 and exit translation; database error semantics remain in the library. Environment transport is the fixed overlay of `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `HINAGATA_RUN_ID`, and `HINAGATA_LEASE_ID` over validated endpoint fields, with service-specific key mapping in the example wrapper. `Cli.Config` owns Settei file/env/argv assembly. Add CLI gates and outputs to existing workspace/Nix files in coordination with their original owners.

Before completion, distill durable discoveries into the cited local ADRs. Commit on the current branch with a Conventional Commit subject and `MasterPlan: docs/masterplans/1-build-hinagata-for-fast-postgresql-fixtures-and-isolated-microservice-tests.md`, `ExecPlan: docs/plans/4-expose-fixture-commands-and-hurl-workbench-handoff.md`, and `Intention: intention_01m3g1rc9re2qa1cy17q25qfq8` trailers. Record implementation provenance through the installed script using the executing model's verified runtime identity.
