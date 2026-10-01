---
id: 5
slug: prove-keiro-service-integration-and-performance
title: "Prove Keiro service integration and performance"
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
      note: "Add clone strategy comparison and concurrent-allocation overlap evidence"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T00:27:54Z
      verdict: "comments"
      note: "Sound; add clone strategy comparison and prove concurrent allocations overlap"
---

# Prove Keiro service integration and performance

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update relevant ADRs when durable decisions change.


## Purpose / Big Picture

A service author can copy a complete Keiro integration example and measure Hinagata's cost for both tiny scenarios and million-row fixture loads. The final deliverable is a verified workflow across migration ownership, database isolation, service configuration, and hurl-workbench, with recorded performance and installable source distributions.


## Progress

- [ ] A public-API Keiro service example migrates, loads, serves, and passes workbench assertions over local sockets.
- [ ] Small/bulk benchmarks and concurrent suites meet recorded gates or receive an explicit evidence-backed plan revision.
- [ ] Published API docs and isolated source distributions reproduce the examples and completed integration checks.


## Surprises & Discoveries


## Decision Log

2026-09-26: Prove the consumer boundary with a runnable local example, not a hard Keiro dependency in core. Measure setup phases separately so bulk loading, migration reuse, and service startup cannot hide one another's costs. Both small scenarios and large datasets are release requirements.

2026-09-30: Add two measurements the architecture review made necessary: compare the `WAL_LOG` and `FILE_COPY` clone strategies on the million-row baseline, and prove from phase timings that concurrent clone allocations overlap instead of queueing on Hinagata's shared-mode baseline lock.


## Outcomes & Retrospective


## Context and Orientation

Hard dependency: `docs/plans/4-expose-fixture-commands-and-hurl-workbench-handoff.md` supplies the complete CLI/handoff. Own `examples/keiro-service/`, `bench/`, `scripts/benchmark.sh`, `docs/performance.md`, and `docs/integration.md`; extend release/CI gates. A baseline is the sealed migrated/base database; a warm run reuses it. Cold measurements include source compilation/building; warm measurements state exactly which artifacts are retained.

[ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md), [ADR 2](../adr/2-stream-fixtures-through-private-postgresql-sessions.md), and [ADR 3](../adr/3-sealed-baselines-and-positive-database-ownership.md) set the integration boundaries. `mori://shinzui/keiro/okf/adrs/concepts/ADR-9` distinguishes schema from ledger verification, and `mori://shinzui/keiro/okf/adrs/concepts/ADR-28` forbids ad hoc private-runtime mutations. `mori://shinzui/keiro/packages/keiro-test-support` is the existing template-pattern reference; do not require its server startup wrapper in production Hinagata. Resolve runtime examples via `mori://shinzui/keiro-runtime-jitsurei` and source APIs through Mori; that project's existing service migration/test layouts are examples, not assumed Hinagata files.

All paths below are repository-relative and proposed unless explicitly described as existing. At planning time only `docs/initial-spec.md`, project metadata, and planning tools existed. The specification now describes the intended library. Dependency research is in `docs/research/initial-design.md`; discover dependency source with Mori before using APIs, then verify current releases with package registries and upstream tags before selecting bounds. Never search the filesystem root or `/nix/store`.

Follow GHC >=9.12, GHC2024, strict unprefixed records, explicit deriving strategies, postpositive qualified imports, and the project prelude. Keep generic-lens orphan imports out of public type-definition modules and the prelude. These conventions come from `mori://shinzui/haskell-jitsurei/docs/core-standards`, `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`.

Every library, executable, test, and benchmark component imports its package's `common common` baseline with GHC2024 and DeriveAnyClass/DuplicateRecordFields/OverloadedLabels/OverloadedStrings. Use generic-lens labels consistently for record access/updates; construction and constructor-directed patterns are valid. Import `Data.Generics.Labels ()` plainly only where required, and inspect transitive imports so public facades do not leak the orphan. Keep entity IDs first in command/event payloads where applicable. Operators stay unqualified; hide clashing prelude exports.

Use MultilineStrings for suitable embedded multiline text per `mori://shinzui/haskell-jitsurei/docs/core-multiline-strings`, preserving external fixture bytes. The [standards audit](../research/haskell-standards-audit.md) records applicability and acceptance ownership. Expected errors are typed; resource cleanup must run on asynchronous exceptions without swallowing them.


## Plan of Work

### Milestone 1: A real runtime consumer

Create an internal example package with a small Keiro service, application-owned reference-data table, migrations, Settei settings, and Hurl assertions. Select a coherent currently released Keiro/Kiroku/PGMQ/pg-migrate cohort after registry/tag verification, and record it. If their released bounds cannot solve together, document the exact conflict and resolve the example cohort deliberately; do not blindly import the older guide's allow-newer workaround. The library packages remain independent of those dependencies.

Compose all required migration components in one complete plan with an application revision covering embedded SQL. Run ledger verification and owner-supplied live-schema verification separately. Base/scenario SQL and CSV may write application-owned reference data. Any event, outbox, or workflow setup uses the runtime's public command/store APIs in an application-owned hook or through the example HTTP flow; do not COPY invented runtime rows. Exercise a command followed by an HTTP read that proves the seeded reference state and runtime behavior work together. If projections are asynchronous, use a public consistency target/readiness predicate with a deadline, not a fixed sleep or fabricated sequence position.

Use the caller's socket cluster and service Settei mapping. Demonstrate separate administration/setup/application roles, an allowed application operation and a denied privileged operation, and a generated-ID insert after explicit-ID fixtures. A scenario including its base reference fixture must succeed without reloading that fixture. Publish small runnable library examples for prepare-once/repeated-leases and test failures returned as values, in addition to the CLI example. Demonstrate isolation with two service instances on separate ports/leases. Also compose two named database leases and show failure of the second acquisition cleans the first. In this example, required globally installed roles/extensions are setup prerequisites, not hidden operations in fixture SQL.

The real service's suites follow `mori://shinzui/haskell-jitsurei/docs/api-hurl-integration-testing`: resource-family files, explicit independent default reads, opt-in write flows, fixture prerequisites, every-request status and body media-type/semantic assertions, and relevant invalid-input/not-found/permission cases. A write is proved through a subsequent public read. Retry only the eventually consistent observation with a bound; no cross-file capture dependencies or global retries. Hurl/hurlfmt belong in reproducible development/CI tools. Keep in-process handler tests and any generated OpenAPI checks separate from the live packaged-service proof. Entity IDs come first in any example command/event payloads. Workbench supplies startup/readiness, reports, and shutdown; Hinagata adds no HTTP runner.

### Milestone 2: Repeatable latency, throughput, and memory evidence

Create deterministic data generators for 100/1,000-row scenario fixtures and 100,000/1,000,000-row CSV fixtures. Generate large data outside measured loading windows, avoid committing generated megabytes, and record a content checksum. Use identical schema, indexes, constraints, trigger behavior, and durability for Hinagata and baseline `psql` commands. The baseline is one session/transaction, not an artificially slow subprocess-per-row implementation.

Measure cold bundle compilation, cold baseline construction, warm reuse, clone allocation, fixture transaction, release, CLI overhead, and end-to-end service/Hurl time separately using a monotonic clock. Measure retained library sessions independently of fresh CLI invocations. Run at least 30 warm small-scenario samples and 5 repetitions per bulk case after warm-up; report median/p95 with sample counts, and do not present five-sample p95 as a stable tail estimate. Record GHC/RTS flags, PostgreSQL/client versions, OS/CPU/storage, schema/data sizes, concurrency, and whether filesystem caches are warm. Use RTS allocation/residency statistics plus process RSS, explaining that PostgreSQL server memory is separate.

Release targets from the spec are bulk COPY elapsed time <=1.25× equivalent `psql`, incremental client residency <=64 MiB for tenfold input growth, and warm small setup median <250 ms/p95 <500 ms on the documented reference machine. Compare template cloning with rebuild on the same small and large baselines; report speedup without assuming a fixed factor. For the million-row baseline also compare the `WAL_LOG` and `FILE_COPY` clone strategies, recording the checkpoint side effects of `FILE_COPY`, and keep `WAL_LOG` as the default unless the evidence justifies changing the setting. Exercise concurrency 1/4/8 with the configured worker cap and report throughput versus tail latency; show from the lifecycle phase timings that clone allocations overlap under concurrency rather than queueing on Hinagata's baseline lock. Keep microbenchmark noise out of ordinary correctness CI; run release performance gates on a documented reference environment.

Measure queue/lock waits and maximum connection counts, including guard sessions and application pools, under saturated demand. Compare repeated acquisition through one prepared manager with fresh CLI calls. Instrument source reads/migration/COPY calls to prove unchanged base inputs are not rehashed or reloaded per lease. Record the fixture's ANALYZE policy and separate transfer time from analysis and subsequent service-query latency.

If clone creation dominates measured setup, run a bounded spare-clone experiment using disposable owned databases. Compare on-demand allocation and prepared spares for acquisition p95, total preparation/replenishment cost, disk space, and maximum connections at the same concurrency. Record an adopt/defer conclusion; no public pooling API or background daemon is required for completion. Any adoption first updates the spec and lifecycle plan with explicit ownership/cancellation/resource semantics. Never recycle a used clone without recreating it.

When a target misses, profile the specific phase, improve it under the existing ownership/transaction contract, and rerun only affected measurements. Do not disable fsync, constraints, triggers, or isolation to claim speed. Any changed budget/strategy requires an explicit evidence-backed spec/ADR/plan revision before completion. A COPY buffer size or clone strategy is a measured tuning choice, not an excuse for multiple public execution models.

### Milestone 3: Reproducible adoption

Add `just example-keiro`, `just bench-fixtures`, and `just release-check`. Extend the source distribution checks to build/test from unpacked archives in a temporary directory; no sibling checkout may be required. Run the conventions gate over every package/component, verify parser-derived completions and informational commands without configuration/database access, and verify version output for local, Nix, and no-Git archive builds. Record actual revision availability rather than fabricating a SHA. Document socket/direct-load, warm baseline, named leases, fixture validation, preservation, migration revision invalidation, and workbench suite scope. Include API Haddocks and a compatibility matrix for the actually tested compiler/PostgreSQL/OS cohort. Target PostgreSQL 18 first, consistent with the inspected Keiro schema baseline; additional versions are supported only when tested.

Run the Keiro example with a changed migration revision and changed base fixture to demonstrate invalidation. Test cancellation and readiness failure across the full nested process/lease scope. Distill cross-plan lessons into ADRs, reconcile registry status, and close the MasterPlan only when all behavior and release gates have evidence.


## Concrete Steps

Run from the Hinagata repository root. The commands below are acceptance interfaces to create in this plan or consume from its prerequisites; they are not claimed to work in the original documentation-only tree.

```bash
nix develop -c just example-keiro
nix develop -c just bench-fixtures
nix develop -c just release-check
nix develop -c just check
```

The integration example passes its actual Hurl assertions, reports the clone endpoint, and leaves no unpreserved owned database/process after normal completion. Concurrent examples see different seeded data. Migration and base-fixture changes invalidate only appropriate generations. The benchmark writes machine-readable results and a human summary to a private/ignored artifact directory; `docs/performance.md` records measured medians/p95, throughput/residency, methodology, and gate verdicts. Release checks build/test unpacked distributions and fail on missing data/manifests or hidden checkout dependencies. No unmeasured performance claim appears in README.


## Validation and Acceptance

Acceptance requires the observable results above, passing focused tests, and the repository checks appropriate to the completed components. Record concise evidence here and in Progress; do not report planned commands as executed. Build documentation from the exposed library API and keep examples runnable. Update dependency metadata and check source distributions when adding a package or public module.


## Idempotence and Recovery

Benchmarks and examples use an explicitly disposable cluster or owned lease, never a developer's persistent database by default. Generate inputs into ignored directories and do not remove unrelated artifacts. Cancellation uses the production cleanup contract. Performance optimization must keep all relevant correctness tests passing; revert only the unsuccessful optimization, preserving other contributors' work.


## Interfaces and Dependencies

The example consumes public Hinagata APIs/CLI and public Keiro runtime APIs; it defines no alternative fixture/lease types. Benchmark instrumentation consumes library stage reports and adds external elapsed/RSS measurements. Core and database packages remain the owners of their APIs; this plan may make measured corrections there but must update the affected ADR, child plan, and MasterPlan integration entry. Source distribution/build gates are shared workspace artifacts created by the first plan and extended here.

Before completion, distill durable discoveries into the cited local ADRs. Commit on the current branch with a Conventional Commit subject and `MasterPlan: docs/masterplans/1-build-hinagata-for-fast-postgresql-fixtures-and-isolated-microservice-tests.md`, `ExecPlan: docs/plans/5-prove-keiro-service-integration-and-performance.md`, and `Intention: intention_01m3g1rc9re2qa1cy17q25qfq8` trailers. Record implementation provenance through the installed script using the executing model's verified runtime identity.
