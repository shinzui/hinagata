---
id: 1
slug: compile-deterministic-fixture-plans-and-typed-configuration
title: "Compile deterministic fixture plans and typed configuration"
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
      at: 2026-09-27T00:02:36Z
      mode: "update"
      note: "Require nix-haskell-flake bootstrap and preserve managed environment ownership."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T00:16:29Z
      mode: "update"
      note: "Incorporate prior-art source review into contracts and acceptance."
---

# Compile deterministic fixture plans and typed configuration

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update relevant ADRs when durable decisions change.


## Purpose / Big Picture

A Haskell caller can compile fixture sources into a deterministic, reusable plan and resolve typed settings without connecting to PostgreSQL. Bad dependency graphs, escaping paths, and invalid settings produce actionable errors before any mutation. This delivers the first buildable package and the data contract consumed by loading and lifecycle operations.


## Progress

- [ ] A released dependency cohort builds and the pure fixture graph tests pass.
- [ ] SQL/CSV source bundles have deterministic plans/digests and reject invalid or changing sources.
- [ ] Settei configuration schema, precedence inputs, and redaction are tested without database access.


## Surprises & Discoveries


## Decision Log

2026-09-26: Bootstrap through `mori://shinzui/seihou-modules/templates/nix-haskell-flake` as explicitly requested; preserve managed pins and use its unmanaged customization seam.

2026-09-26: Keep pure descriptions and Settei declarations in `hinagata-core`; native database IO belongs to a separate package. Freeze fixture bytes into reusable bundles so freshness and execution agree. Include ordered CSV COPY descriptions from the start because large bulk loads are a first-release requirement.


## Outcomes & Retrospective


## Context and Orientation

There are no hard dependencies. Own `hinagata-core/hinagata-core.cabal`, `hinagata-core/src/Hinagata/{Prelude,Types,Error,Connection,Config}.hs`, `hinagata-core/src/Hinagata/Fixture/{Types,Graph,Manifest,Bundle,SqlPolicy}.hs`, and `hinagata-core/test/Main.hs`. Bootstrap the dev environment with `mori://shinzui/seihou-modules/templates/nix-haskell-flake`; retain its managed flake/lock/formatter ownership. Create `cabal.project`, `justfile`, a license, and `README.md`, and put workspace-specific Nix outputs/tools in the unmanaged `flake.module.nix`. Adopt the repository's identity without changing branches.

[ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md) separates library and consumer ownership; [ADR 2](../adr/2-stream-fixtures-through-private-postgresql-sessions.md) requires immutable plans and streaming-friendly descriptions. `mori://shinzui/settei/okf/adrs/concepts/ADR-2` supplies inspectable configuration semantics; do not invent a monadic settings language. A fixture closure is the requested fixture plus every transitive include, applied once in dependency order. A bundle is a private local copy of the source bytes plus their hashes, so the later load executes exactly what was planned.

All paths below are repository-relative and proposed unless explicitly described as existing. At planning time only `docs/initial-spec.md`, project metadata, and planning tools existed. The specification now describes the intended library. Dependency research is in `docs/research/initial-design.md`; discover dependency source with Mori before using APIs, then verify current releases with package registries and upstream tags before selecting bounds. Never search the filesystem root or `/nix/store`.

Follow GHC >=9.12, GHC2024, strict unprefixed records, explicit deriving strategies, postpositive qualified imports, and the project prelude. Keep generic-lens orphan imports out of public type-definition modules and the prelude. These conventions come from `mori://shinzui/haskell-jitsurei/docs/core-standards`, `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`. Expected errors are typed; resource cleanup must run on asynchronous exceptions without swallowing them.


## Plan of Work

### Milestone 1: A buildable pure planner

First inspect the installed Seihou template and its authoritative module descriptor, then preview and apply `nix-haskell-flake` using the command below. Mori metadata and the README version heading lag the local descriptor, so verify the installed/current module through Seihou rather than pinning that stale heading. Use the managed toolchain and exact lock; do not hand-author a replacement flake or change managed pins. Disable the built-in single-root-package output because this is a multi-package workspace. Add workspace outputs, checks, and extra tools through `flake.module.nix`; enable PostgreSQL tooling for the test harness without making the production library bootstrap a server. Stage Nix inputs/modules before evaluating a git-backed flake so Nix sees the canonical lock. Keep local exports in `.envrc.local` and optional local processes in `process-compose.override.yaml`. Never hand-edit generated `nix/haskell.nix` for project customizations.

Create the core library and its tests with a common Cabal stanza using GHC2024 and the baseline DeriveAnyClass, DuplicateRecordFields, OverloadedLabels, and OverloadedStrings extensions. Use a small `Hinagata.Prelude`, with PackageImports only in that module. Inspect released metadata for Settei, YAML decoding, hashing, lens/generic-lens, and test dependencies; choose a coherent GHC >=9.12 toolchain and pin the application/test solver reproducibly without overconstraining the library. Research found Settei 0.2.0.0 and a newer Hasql API than the local corpus; neither observation is a substitute for a solver run. No Hasql dependency is needed in core.

Define validated opaque `FixtureName`, `DatabaseName`, `ProjectId`, `RunId`, `SqlIdentifier`, `Port`, and positive worker/chunk/deadline values. Endpoint construction distinguishes socket directories from TCP hosts. Quote libpq keyword values correctly and return parse errors for malformed strings; never turn invalid input into empty/default settings. A credential wrapper must not derive a revealing Show instance. Test socket paths containing spaces, apostrophes, and backslashes, Unicode byte-length limits for identifiers, empty/invalid ports, and secret display.

Implement `resolveFixtures` as a pure stable depth-first traversal retaining requested/include order. Deduplicate diamond dependencies, reject cycles with full paths, and distinguish duplicates, missing nodes, and malformed names. Give it a hand-built in-memory graph test before adding disk loading.

### Milestone 2: Executable source bundles

Decode the manifest format in `docs/initial-spec.md` with strict unknown-field checking, non-empty explicit step lists, name/directory agreement, and an unambiguous rule: an explicit steps list replaces implicit `fixture.sql`, never silently appends it. Resolve paths relative to each fixture directory within the configured root, canonicalize symlinks, and reject escapes. Compile all dependencies before exposing a plan.

Create private bundle directories by atomic temporary-directory publication. Copy/hash CSV in fixed-size chunks; read bounded SQL steps once. Hash a versioned canonical encoding of ordered names, includes, step kinds/options, lengths, and content digests, not filesystem mtimes or unspecified Map/Show output. Reject source changes detected during capture and do not publish partial bundles. Execution uses captured data even if original sources subsequently change. Persistent cached bundles must be integrity-checked before reuse; library calls can retain a validated in-process plan to avoid repeated hashing. An incomplete/modified cache is rebuildable.

Preserve per-fixture canonical identities and the resolved graph in the bundle manifest. Add a pure composition operation that resolves base roots before scenario roots and returns the base prefix plus remaining steps. Shared names require identical captured definitions/content/dependencies. Refuse mismatches before producing an executable remainder; tests cover shared dependencies, conflicting bytes/options/includes, unrelated base fixtures, and stable order. This operation alone confers no database reuse authority; the lifecycle layer must verify the corresponding baseline. Direct loads still execute their entire plan on every call.

Implement the SQL policy scanner needed to reject top-level transaction control (including BEGIN/START TRANSACTION, COMMIT/END, ROLLBACK/ABORT, SAVEPOINT/RELEASE, and PREPARE TRANSACTION), COPY statements, and psql commands. Handle nested comments, standard/escape strings, quoted identifiers, and dollar-quoted bodies. It is a policy lexer, not full SQL validation; do not reject a dollar-quoted function body merely because it contains those words. Keep SQL bytes intact for PostgreSQL. Document trusted stored functions/external effects and limits of this check.

### Milestone 3: Typed configuration declaration

Define `hinagataConfig :: Settei.Config HinagataConfig` with explicit endpoint, project identity, fixture/bundle paths, maintenance database/schema, explicit administration/setup/application access, deadlines, setup-worker/active-lease/pending-request limits, chunk size, and SQL size limit. No default database authorizes mutation. Declare the concurrency limits as manager-local and keep the three access purposes explicit; never default an application endpoint from administrative credentials. Operational defaults are visible Settei sources/rules. Provide validated explicit environment bindings; no wildcard environment discovery. Retain library callers' ability to construct resolved values directly. Source file IO and optparse wiring remain CLI work.

Create `just check`, `just fmt-check`, and focused core-test commands; make the Nix gate validate the package and tests. Publish module documentation and source-distribution checks. All command additions must execute real gates rather than placeholders.


## Concrete Steps

Run from the Hinagata repository root. The commands below are acceptance interfaces to create in this plan or consume from its prerequisites; they are not claimed to work in the original documentation-only tree.

```bash
seihou run nix-haskell-flake --dry-run \
  --var project.name=hinagata \
  --var project.description='Reproducible PostgreSQL fixtures and test databases' \
  --var ghc.version=ghc9124 --var nix.builtin-package=false \
  --var nix.process-compose=false --var nix.postgresql=true --var nix.pg-package=postgresql_18 \
  --var nix.redis=false --var nix.clickhouse=false --var nix.kafka=false --var nix.redpanda=false \
  --var nix.treefmt=true --var nix.pre-commit=true
seihou run nix-haskell-flake \
  --var project.name=hinagata \
  --var project.description='Reproducible PostgreSQL fixtures and test databases' \
  --var ghc.version=ghc9124 --var nix.builtin-package=false \
  --var nix.process-compose=false --var nix.postgresql=true --var nix.pg-package=postgresql_18 \
  --var nix.redis=false --var nix.clickhouse=false --var nix.kafka=false --var nix.redpanda=false \
  --var nix.treefmt=true --var nix.pre-commit=true
git add flake.nix flake.lock nix/ flake.module.nix
seihou status
nix develop -c cabal build hinagata-core
nix develop -c cabal test hinagata-core-test --test-show-details=direct
nix develop -c just check
nix develop -c cabal sdist hinagata-core
```

Seihou status must show no unintended edits to managed files; evaluating the dev shell must retain the generated lock. `flake.module.nix` must expose the actual workspace packages/checks. Tests must show a diamond closure applied once in stable order, a reported A→B→C→A cycle, and zero use of a mutation interpreter for every invalid graph/path. Repeated compilation produces the same digest; changed SQL, CSV bytes, include order, COPY options, or migration-relevant config changes the appropriate identity. A tenfold CSV input does not require tenfold memory. Configuration tests force binding construction and show that later supplied Settei sources win while secrets are redacted in both success and failure reports.


## Validation and Acceptance

Acceptance requires the observable results above, passing focused tests, and the repository checks appropriate to the completed components. Record concise evidence here and in Progress; do not report planned commands as executed. Build documentation from the exposed library API and keep examples runnable. Update dependency metadata and check source distributions when adding a package or public module.


## Idempotence and Recovery

Compilation never mutates a database. Write bundles to temporary paths and publish only complete manifests; remove only this operation's incomplete directory on failure. Repeated valid compilation reuses verified content or safely rebuilds it. Do not overwrite user fixtures or package metadata created concurrently.


## Interfaces and Dependencies

`Hinagata.Fixture.Types` owns `FixtureDefinition`, ordered `FixtureStep` (`SqlFile` or `CopyCsv`), and opaque `FixturePlan`. `Hinagata.Fixture.Graph.resolveFixtures` returns an ordered closure or typed diagnostics. `Hinagata.Fixture.Bundle.compileFixtures` returns a validated plan over frozen sources. `Hinagata.Connection` owns validated `ConnectionTarget` and secret-safe rendering; it has no database handle. `Hinagata.Config` owns the Settei declaration; later packages extend through composition, not duplicate environment parsing. `Hinagata.Error` owns common diagnostic context; backend and CLI-specific errors remain in their packages.

Before completion, distill durable discoveries into the cited local ADRs. Commit on the current branch with a Conventional Commit subject and `MasterPlan: docs/masterplans/1-build-hinagata-for-fast-postgresql-fixtures-and-isolated-microservice-tests.md`, `ExecPlan: docs/plans/1-compile-deterministic-fixture-plans-and-typed-configuration.md`, and `Intention: intention_01m3g1rc9re2qa1cy17q25qfq8` trailers. Record implementation provenance through the installed script using the executing model's verified runtime identity.
