# Haskell standards applicability audit

Audited 2026-09-26 against the Mori-discovered working tree of `mori://shinzui/haskell-jitsurei`, Git HEAD `6c83df0d5955dba1d523d5cf6f748effb558a4e3`. This is an audit of planning coverage, not certification of code that does not yet exist or an independent review of the source standards.

## Finding and corrections

The original plan explicitly covered the compiler/language baseline, four mandatory extensions, strict unprefixed fields, explicit deriving, postpositive imports, a project prelude, and orphan-instance isolation. It cited the right core guides but did not spell out every applicable requirement or its acceptance owner. The corrections below make those requirements reviewable across all packages.

| Source | Applicability and planned acceptance | Owner |
| --- | --- | --- |
| `mori://shinzui/haskell-jitsurei/docs/core-standards` | Every package uses a `common common` stanza with GHC2024, DeriveAnyClass, DuplicateRecordFields, OverloadedLabels, and OverloadedStrings. Every library, executable, test, and benchmark imports it. GHC >=9.12; qualified imports are postpositive. | EP-1 establishes; all package-producing plans extend; EP-5 checks distributions. |
| `mori://shinzui/haskell-jitsurei/docs/core-record-patterns` | Strict unprefixed data-record fields; explicit stock/newtype/anyclass strategies; entity ID first for command/event payloads where applicable. Prefer generic-lens labels for record access/updates and `at`/`ix` for nested map changes. Construction and constructor-directed pattern matching remain valid. Keep label orphans out of definition modules and consumer-facing module import closures. | All five plans; EP-1 provides conventions gate. |
| `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude` | Expose `Hinagata.Prelude` from core. Package-qualified re-exports and a local PackageImports pragma; common Text/Generic/Aeson/time types and Control.Lens exports. No domain types or generic-lens orphan import. Resolve clashes by hiding the unwanted prelude name; operators remain unqualified. Centralize serialization options while preserving explicit secret-safe codecs. | EP-1 establishes; EP-4 owns CLI wire encoding. |
| `mori://shinzui/haskell-jitsurei/docs/core-multiline-strings` | Use MultilineStrings for suitable embedded multiline SQL/text. External fixture files retain exact captured bytes; do not transform them to follow a source-code style rule. Keep file-specific extensions local. | EP-2/3 internal SQL; EP-4 embedded text. |
| `mori://shinzui/haskell-jitsurei/docs/cli-option-groups` | Select readable option groups for connection, fixture, lifecycle, and output controls without changing parser behavior. Verify against the released parser library during implementation. | EP-4. |
| `mori://shinzui/haskell-jitsurei/docs/cli-shell-completions` | Select parser-derived Bash/Zsh/Fish completions; generation and completion queries do not connect to PostgreSQL or require operational configuration. | EP-4. |
| `mori://shinzui/haskell-jitsurei/docs/cli-version-git-sha` | Select package version plus available build revision, with honest dirty/unknown handling. Build from a source archive without Git. Put Nix wiring in the Seihou-supported unmanaged module. | EP-4 implements; EP-5 checks local/Nix/archive builds. |
| `mori://shinzui/haskell-jitsurei/docs/api-hurl-integration-testing` | Applies to the example HTTP services: live packaged server, resource-family suites, status/media-type/semantic assertions, relevant failures, explicit independent default files, isolated opt-in writes, bounded observation retries, hurlfmt, and documented fixture prerequisites. Workbench owns orchestration. | EP-4/5 examples. |

EP references above name the numbered plans in `docs/plans/`; the [MasterPlan registry](../masterplans/1-build-hinagata-for-fast-postgresql-fixtures-and-isolated-microservice-tests.md#exec-plan-registry) provides their paths. The setup checklist was also checked: canonical project `mori://shinzui/haskell-jitsurei`, project-relative `mori/checklist.dhall`, key `adopt-haskell-conventions` (artifact-level URI pending).

## Scope and interpretation

The CLI overview explicitly says to select the smallest applicable patterns. Embedded help topics, terminal-aware topic reflow, fzf, clipboard support, stdin fixture import, aliases, and agent integrations are not initial requirements merely because they appear in the catalog. Ordinary `--help` remains required. The selected completion/version/grouping patterns suit the planned CLI.

`mori://shinzui/haskell-jitsurei/docs/cli-hierarchical-config` is deprecated. The user's Settei instruction and the selected Settei standard remain authoritative; do not introduce legacy Dhall settings or a parallel configuration mechanism.

Production Servant deployment, Relay pagination, and telemetry patterns do not impose an HTTP server on Hinagata. The internal example follows relevant HTTP contracts for the endpoints it actually exposes; detailed production API features are not added solely to demonstrate fixtures. Keep Haskell handler tests and any generated OpenAPI checks distinct from live Hurl acceptance.

Some illustrative source snippets predate their surrounding prose: the custom-prelude guide shows a package-qualified label import outside the prelude, and CLI snippets use older import/access styles. Follow the explicit core rules and the record guide's plain per-module `import Data.Generics.Labels ()`; do not copy contradictory snippets. Orphan instances propagate transitively, so checking only the prelude import line is insufficient. Public facades must not re-export an implementation module that introduces the orphan; use constructor patterns or explicit internal optics where necessary to keep that boundary clean.

The source catalog's review/provenance policy governs changes to its own pattern concepts. Hinagata plans retain the installed master-plan/exec-plan provenance workflow. No upstream pattern or review record is changed by this audit. Dependency examples are not pins: Mori source discovery and authoritative release verification are still required before choosing bounds.

## Completion evidence

EP-1 adds a conventions check to `just check` for component baseline coverage, postpositive imports, and PackageImports placement, plus a documented source review for record/optic style and transitive orphan exposure. Later plans extend it to their components. EP-4 proves informational commands work without a database. EP-5 checks the same conventions and tooling from unpacked distributions and records the live HTTP acceptance evidence. At audit time every implementation item remains pending.
