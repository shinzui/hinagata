# Initial design evidence

Researched 2026-09-26. This records planning evidence, not completed implementation or measured performance.

## Starting tree and Haskell standards

The starting tree contains `docs/initial-spec.md`, Mori identity, Mina configuration, and plan skills. There were no packages, tests, build gates, plans, or local ADRs. The old spec ends partway through its configuration scope.

Mori located `mori://shinzui/haskell-jitsurei/docs/core-standards`, `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`, and `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`. These require GHC >=9.12, GHC2024, baseline DeriveAnyClass/DuplicateRecordFields/OverloadedLabels/OverloadedStrings, explicit deriving, strict unprefixed fields, and postpositive qualified imports. Keep `PackageImports` local to the project prelude and `Data.Generics.Labels ()` out of the prelude and public type definitions, avoiding orphan label instances in Keiki consumers.

`mori://shinzui/haskell-jitsurei/docs/cli-hierarchical-config` explicitly deprecates its older approach. Its replacement, `mori://shinzui/keiro-runtime-patterns/docs/config-settei-cli-standard`, specifies ordered sources, standard diagnostics, redaction, and direct format adapters where appropriate. Historical dependency workarounds must be rechecked against released packages.

## Consumer boundaries and ADRs

`mori://shinzui/keiro/packages/keiro-test-support`, module `Keiro.Test.Postgres`, already creates one migrated template and clones per example. Its public `withFreshDatabase` passes a connection string. It closes migration connections before cloning and stores before deletion. Hinagata generalizes the lifecycle to an existing server; it need not start the helper's ephemeral server. Do not copy the helper's unescaped keyword-string construction for general socket paths.

`mori://shinzui/keiro/okf/adrs/concepts/ADR-9` separates ledger verification from live-schema verification. `mori://shinzui/keiro/okf/adrs/concepts/ADR-28` requires supported owner APIs for runtime state and application hooks for operations needing compiled application code. The example must compose the complete migration plan and use public APIs for event/runtime writes.

`mori://shinzui/settei/okf/adrs/concepts/ADR-2` defines inspectable applicative/selective `Config`, without Monad. Its source confirms public `resolve`, explicit environment bindings, ordered sources, and direct YAML support. Configuration declaration and source IO therefore remain separate.

Mori currently has no indexed ADR bundle or DocRefs for `mori://shinzui/hurl-workbench`. Through that canonical project, the checked-in `docs/adr/5-bounded-isolated-batch-execution.md` and `docs/adr/6-managed-service-process-group-lifecycle.md` were read; artifact-level URIs are pending. They establish bounded independent Hurl execution and suite-owned process-group readiness/cleanup. The same project's `docs/reference/workspace.md` (artifact-level URI pending) supports suite-level service environment parameters, not per-case database-fixture hooks. Integrate through an outer lease around a suite; parallel isolated scenarios need separate invocations and service instances. No workbench modification is required.

## Dependency release checks

Mori's Hasql source is 1.10.3.5. [Hackage preferred versions](https://hackage.haskell.org/package/hasql/preferred.json) and `nikita-volkov/hasql` upstream tags show 2.0.1.0. Its [package metadata](https://hackage.haskell.org/package/hasql-2.0.1.0) describes a new pluggable transport. Do not assume the local 1.10 `Session.onLibpqConnection` API exists in current Hasql. Hinagata-owned endpoints prevent a driver choice from forcing consumer migrations.

Mori found no registered `postgresql-libpq` source. After that lookup, [upstream v0.11.0.0 source](https://github.com/haskellari/postgresql-libpq/blob/v0.11.0.0/src/Database/PostgreSQL/LibPQ.hs), [Hackage preferred versions](https://hackage.haskell.org/package/postgresql-libpq/preferred.json), metadata, and tags were checked. They agree on 0.11.0.0, peeled tag `a9122f8ecc11365a26a5489b3a2e1cdf64c0c661`. Public source exports SQL/results, `putCopyData`, `putCopyEnd`, and `CopyInWouldBlock`, and warns against use after explicit `finish`. The private adapter must enforce exclusive lifetime and protocol recovery; it is not a public query abstraction.

[Settei preferred versions](https://hackage.haskell.org/package/settei/preferred.json) and upstream tags agree on 0.2.0.0, peeled tag `1bf62b0af110b4f42fe2528e9d459e0ccf12d626`. These observations are not dependency bounds or a solved cohort. Recheck registries/tags, source APIs, GHC compatibility, and the service migration cohort when implementing. Do not add `allow-newer` from stale guidance.

## PostgreSQL constraints

[CREATE DATABASE](https://www.postgresql.org/docs/18/sql-createdatabase.html) documents permissions, transaction restrictions, idle templates, and omitted database grants/settings. Its default WAL_LOG strategy suits small templates; FILE_COPY introduces checkpoints and needs measurement before any override. This motivates sealed baselines and explicit clone preparation.

[Connection parameters](https://www.postgresql.org/docs/18/libpq-connect.html) define socket directories in `host` and keyword escaping. The [COPY protocol](https://www.postgresql.org/docs/18/libpq-copy.html) requires COPY completion and draining final results before further SQL. [COPY SQL](https://www.postgresql.org/docs/18/sql-copy.html) supplies CSV semantics and client-streamed input. The design uses bounded native streaming with one connection/transaction.

## Seihou bootstrap

The user explicitly selected `mori://shinzui/seihou-modules/templates/nix-haskell-flake`. Mori resolves its module directory; its README and module descriptor establish managed `flake.nix`, canonical `flake.lock`, `nix/*.nix`, and formatter files, with project changes in unmanaged `flake.module.nix`, `.envrc.local`, and `process-compose.override.yaml`. Disable the built-in single-root package output for Hinagata's workspace. Stage Nix-visible files before evaluation. Mori's indexed template version and the README heading lag local migrations; select/verify the installed current template through Seihou, not the stale heading. This planning change records bootstrap instructions; it does not apply the template yet.
