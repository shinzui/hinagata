---
id: 7
slug: derive-baseline-hook-revisions-from-declared-content-inputs
title: "Derive baseline hook revisions from declared content inputs"
kind: exec-plan
created_at: 2026-10-18T18:43:31Z
intention: "intention_01m5854hr5e08bx5q3mjrbepkj"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-18T18:43:31Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-18T18:59:54Z
      mode: "update"
      note: "Correct example hook precedence and verifier inputs; specify offline validation, array overrides, and scoped redaction acceptance."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-18T19:00:31Z
      verdict: "approved"
      note: "Reviewed and corrected CLI validation/precedence, verifier dependency declarations, and diagnostic acceptance against source and ADRs; revised plan is implementable, with implementation tests still pending."
---

# Derive baseline hook revisions from declared content inputs

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Distill changes to durable architectural context into the existing ADRs.


## Purpose / Big Picture


A service author will be able to declare the files and non-secret values that determine migration and verification behavior. Hinagata will derive revision strings from those contents before deciding whether a sealed PostgreSQL baseline can be reused. Editing external migration SQL will then invalidate the baseline even when the migration executable itself is unchanged.

This plan implements [IR-2: Derive baseline hook revisions from declared content inputs](../improvement-requests/derive-baseline-hook-revisions-from-declared-content-inputs.md), preserving its AC-1 through AC-5. The existing manual revision interface remains supported. Omitting both a manual revision and declared inputs retains the current behavior: persistent reuse is disabled when either baseline hook lacks a revision. The helper identifies only declared inputs; it does not discover arbitrary executable dependencies or infer remote state.


## Progress


- [ ] Milestone 1: A reusable helper derives versioned revisions from named file contents and values, with deterministic ordering, relocation-independent results, and safe input failures (AC-1, helper portion of AC-3).
- [ ] Milestone 2: CLI declarations feed derived revisions into existing baseline preparation, validate inputs before reuse, reject conflicting modes, and preserve manual/missing-revision behavior (AC-2, AC-3, AC-4).
- [ ] Milestone 3: A disposable service example demonstrates independent executable, SQL, manifest, verification-code, and non-secret configuration invalidation, including unchanged-executable external SQL changes (AC-2, AC-5).
- [ ] Milestone 4: Documentation, ADRs, packaged sources, and regression evidence establish the declared-input boundary; IR-2 is completed only after AC-1 through AC-5 pass.

Implementation has not started. IR-2 is accepted and linked to this plan; no acceptance criterion is claimed verified.


## Surprises & Discoveries


2026-10-18 review: `scripts/example-keiro.sh` exports `HINAGATA_VERIFICATION_EXECUTABLE`, and environment bindings override YAML. Leaving that export in place would bypass the proposed verification wrapper. Also, `examples/keiro-service/migration/Main.hs` constructs the complete migration plan for verification, so after externalization the verifier will consume the application SQL and manifest as well as its own SQL. Both hook declarations must cover those shared inputs.

2026-10-18 review: Settei's current `--set` adapter supplies text scalars; its list decoder accepts only arrays. Array replacement therefore requires a later YAML file. Existing configuration explanations intentionally expose public settings such as executable, cwd, and fixture roots; new revision-input redaction tests must distinguish these from sensitive declared-input fields.


## Decision Log


2026-10-18: Derive an ordinary revision string before invoking the existing baseline library. Keep the baseline fingerprint version, catalog format, ownership rules, and `BaselineSpec` revision types unchanged. This is an authoring facility over the established cache contract.

2026-10-18: Expose named file inputs, explicitly selected executable bytes, and named non-secret literal values under each baseline hook. Separate physical file locations from logical names in the digest. Preserve explicit revisions and reject simultaneous explicit and derived declarations.

2026-10-18: Verify selected contents before preparation, around build-time hook execution, and before returning a reuse/build result. The supported contract requires inputs to remain stable throughout preparation; these checks detect changes at those boundaries but do not claim an atomic snapshot of arbitrary external executable dependencies.

2026-10-18: Keep this plan independent of [ExecPlan 6](6-expose-clone-preparation-hooks-through-the-cli.md). That plan exposes per-clone seeding, which stays outside the baseline fingerprint. This plan applies only to migration and verification. Shared CLI configuration changes must accommodate either implementation order.

2026-10-18: Set IR-2 to `accepted` with its target plan when planning is complete, to `in-progress` when implementation starts, and to `completed` only after acceptance evidence. Preserve the original acceptance criteria and review provenance.


## Outcomes & Retrospective


(To be filled during implementation and after acceptance.)


## Context and Orientation


A hook is a service-owned migration or verification command. A hook revision is the caller's identity for that command's effects. A baseline is a migrated, fixture-loaded, verified database sealed for use as a PostgreSQL template. Its fingerprint is a digest of all declared baseline identity components. A logical input name identifies an input's purpose, such as `application/sql`; its physical path merely locates bytes on the current machine.

`hinagata-postgres/src/Hinagata/Postgres/Baseline.hs` defines `BaselineSpec.migrationRevision` and `.verificationRevision` as `Maybe Text`. `fingerprintManifest` includes those values alongside fixture identity, server/configuration, and role requirements. `prepare` sets `reusable = isJust migrationRevision && isJust verificationRevision`. Only then can `lookupReady` return an existing generation. Hook execution is skipped on reuse. Missing revisions intentionally force a new generation, even if other inputs match. Construction calls the migration hook, loads baseline fixtures, invokes verification, checks requirements, seals the database, and publishes it.

`hinagata-cli/src/Hinagata/Cli/Config.hs` declares `HookSettings` for migration and verification. `resolveConfig` combines built-in defaults, YAML files in order, explicit environment bindings, and repeated `--set` overrides. Arguments and environment arrays are secret settings. `hinagata-cli/src/Hinagata/Cli/Command.hs` assembles the baseline in `prepareBaseline` and copies revision strings directly from those settings. Its `hookRunner` validates command settings and uses `hinagata-cli/src/Hinagata/Cli/Process.hs` to supply setup access without a shell.

`hinagata-cli/app/Main.hs` resolves configuration before dispatch. Schema/help paths bypass operational work. `--check-config` returns through `resolutionDiagnostic` without invoking `prepareBaseline`, so adding validation only to baseline preparation will not validate declarations offline. Concurrent implementation of ExecPlan 6 is introducing `validateHook` in `hinagata-cli/src/Hinagata/Cli/Config.hs`; extend the resulting pure validation path when available instead of duplicating it. `db prepare`, `db acquire`, `db with`, and `fixture validate` use baseline preparation. `fixture plan` and direct `fixture load` do not need baseline identity. `hinagata-cli/src/Hinagata/Cli/Output.hs` emits versioned reports through `CliError`; avoid placing selected input contents, physical paths, or raw filesystem errors in new diagnostics.

`hinagata-core/src/Hinagata/Fixture/Bundle.hs` already uses incremental SHA-256 to hash file contents in fixed-size chunks. `hinagata-core/hinagata-core.cabal` directly depends on `cryptohash-sha256`, `bytestring`, filesystem libraries, and test utilities. A reusable content-revision helper belongs in this package, while CLI option resolution and process assembly stay in the CLI. Avoid exporting a fixture-specific private helper solely to reuse a few hashing lines.

`scripts/test-cli.sh` is the offline CLI smoke test. `scripts/test-cli-postgres.sh` exercises real baseline preparation against a disposable cluster started by `scripts/test-postgres.sh --cli`. `scripts/example-keiro.sh` currently hashes the built migration executable with `shasum` and exports that hash as both manual revisions. The example embeds application SQL in `examples/keiro-service/migration/Main.hs`, so that existing approach correctly covers its present SQL. It does not establish identity for arbitrary external files read by other services.

Relevant decisions are [ADR 1](../adr/1-library-boundary-and-service-owned-postgresql.md) and [ADR 3](../adr/3-sealed-baselines-and-positive-database-ownership.md). ADR 1 keeps migrations and verification service-owned and the CLI thin. ADR 3 requires truthful migration/verification identities for reuse, leaves opaque effects under caller control, and defines immutable generations with positive ownership checks. Extend those explanations for derived identities without changing database ownership or the template lifecycle. The ADR corpus uses ordinary Markdown; `mori.dhall` declares no profiled ADR bundle.

The originating adoption work is `mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract`. This is a local implementation plan, not a child of that external MasterPlan. Existing completed baseline behavior in the working tree is sufficient to begin. IR-1 per-clone preparation and IR-3 Linux CI evidence remain separate obligations.


## Plan of Work


### Milestone 1: Implement the reusable deterministic helper


Create `hinagata-core/src/Hinagata/Hook/Revision.hs`, expose it in `hinagata-core/hinagata-core.cabal`, and add focused tests in `hinagata-core/test/Main.hs`. Define named file and named value inputs, an opaque captured-input result holding revision/evidence, and safe errors. Suggested public operations are `deriveHookRevision` to read files and construct a revision and `verifyHookRevisionInputs` to compare currently selected files with captured evidence. Use smart constructors for logical names and avoid `Show` instances that expose physical paths, file bytes, or literal values. CLI callers must be able to obtain the printable revision and safe labels/types for an explanation without accessing file contents.

Use SHA-256 over an explicitly versioned, unambiguous binary encoding. For version 1, begin with UTF-8 bytes `hinagata-hook-revision-v1` followed by a zero byte, then a big-endian unsigned 64-bit entry count. Sort entries by their logical name's UTF-8 bytes. Encode each name as its byte length followed by those bytes. Follow it with a one-byte kind tag: 1 for a file and 2 for a value. A file payload is its unsigned 64-bit byte count followed by its 32 raw SHA-256 digest bytes; a value payload is its unsigned 64-bit UTF-8 byte length followed by its bytes. Every length uses the same big-endian encoding. The printable result is `hinagata-hook-revision-v1:sha256:` followed by 64 lowercase hexadecimal digits. Commit known-answer test vectors so this format cannot drift accidentally.

Require normalized ASCII names beginning with a lowercase letter and containing lowercase letters, digits, dots, underscores, hyphens, or slashes; reject empty slash components and `.` or `..` components. Reject duplicate names across all kinds, including the reserved `executable` name used by the CLI's executable selector. Input order and filesystem enumeration order do not affect the digest. A label or kind change does change it. File modification/access times, absolute paths, inode numbers, and file permissions are excluded. Read exact bytes with no newline or whitespace normalization. Equivalent literal values use the same UTF-8 text representation; do not infer semantic equivalence of arbitrary JSON/SQL.

Read each declared file with bounded memory and catch filesystem failures without retaining raw exception text in public errors. Compute the encoded byte count from the same bytes fed to the hash, not a separate filesystem size query. Reject directories and non-regular stream inputs rather than blocking on a pipe. Permit symlinks to regular files, hash the target bytes, and re-resolve/recheck them during evidence verification. The target's absolute path is still excluded from identity. File execute permission is not a digest input; process startup remains responsible for executing a selected command. The helper's version-1 input set must be nonempty; CLI absence is represented outside the helper.

Prove equal results across different temporary roots, different list order, and changed modification times; changed results for one-byte changes, renamed inputs, file/value kind changes, and changed literal values; and failure for duplicate/invalid names, missing/unreadable files, directories, and changed/deleted symlink targets. Include boundary-encoding tests for names/values containing delimiters or newlines where permitted. Permission tests must use an actually unprivileged process or an injected failing reader if the test environment can bypass mode bits. `nix develop -c just core-test` independently verifies this milestone.


### Milestone 2: Integrate derived revisions into CLI preparation


Extend each migration/verification settings declaration in `hinagata-cli/src/Hinagata/Cli/Config.hs` with `revision_executable` (Boolean, default false), `revision_inputs` (YAML array, default empty), and `revision_values` (YAML array, default empty). Each file entry is `NAME=PATH`, and each value entry is `NAME=VALUE`; split on the first equals sign so values and paths may contain additional equals signs. Paths must be nonempty and contain no NUL. Empty literal values are valid. Read arrays from YAML using existing Settei decoders; use explicit scalar environment bindings `HINAGATA_MIGRATION_REVISION_EXECUTABLE` and `HINAGATA_VERIFICATION_REVISION_EXECUTABLE`. Do not invent array splitting for environment bindings.

Later YAML files replace each array as a whole; an empty array clears that selector. Scalar `--set` overrides support `revision_executable` and existing scalar settings, but cannot supply or clear arrays. Attempts such as `--set migration.revision_inputs=[]` must fail safely as type errors with exit 4. Switching a layered derived configuration back to manual mode requires clearing both arrays in a later YAML file and setting `revision_executable` false before supplying the manual revision. An explicitly supplied empty manual revision is still present for conflict detection, matching the existing `Maybe Text` interface.

If any derived selector is present with a nonempty effective input set, use derived mode. Otherwise retain manual `revision` or the existing missing-revision behavior. Reject an explicit revision combined with any effective derived selector, and reject derived mode without the hook executable. Validate normalized labels and duplicate names after combining selected executable/files/values. Declare input/value arrays as sensitive for configuration explanations because they contain paths and potentially sensitive caller data, even though supported literal identity values must be non-secret. Error text must name the setting or safe logical label, never the rejected full entry. Share semantic validation with `--check-config`; checking syntax/mode must stay offline and must not read or execute selected files.

Put the pure declaration checks in `Hinagata.Cli.Config` (or a dependency-neutral module) and invoke them on the successfully resolved settings before `resolveConfig` returns success. This places validation before `Main.hs` can emit `configuration valid` or a successful explanation. Keep file capture in `Hinagata.Cli.Revision`; avoid a `Config`/`Revision` import cycle. Schema/help/completion paths must retain their existing bypass of configuration loading. A syntactically valid declaration naming a nonexistent file must pass `--check-config` and fail only on operational preparation.

`revision_executable: true` adds the command executable bytes under reserved name `executable`. Require an absolute executable in this mode to avoid hashing one PATH lookup and executing another. Keep basename executables supported in manual mode or when executable bytes are not selected. Resolve relative file inputs against the hook's explicit absolute `cwd`, or the invocation working directory captured once when no cwd is configured. YAML file location does not implicitly become the input root. Physical paths are for reading only and never enter the digest. Selecting the same contents under the same logical names in another checkout must preserve identity.

Add `hinagata-cli/src/Hinagata/Cli/Revision.hs` for translating settings into the reusable helper, safe errors, and captured evidence; register it in `hinagata-cli/hinagata-cli.cabal`. In `prepareBaseline`, validate commands, derive both revisions, and fail on any unreadable selected input before calling `ensureBaseline`. This ensures an existing ready generation cannot hide a broken declaration. Pass the derived strings into the unchanged `BaselineSpec` revision fields. No migration or verification process may start if initial input capture fails for either hook.

For builds, wrap both command callbacks with evidence checks before and after execution, checking the captured inputs for both hooks so a migration that modifies verification inputs cannot publish a baseline under an outdated identity. Return a safe failure if selected contents changed. Recheck both captured input sets after `ensureBaseline` returns and before reporting `Built` or `Reused`, including reuse after lock waiting. Scope captured state to one preparation call; do not memoize by path or share mutable evidence across concurrent calls. Missing-revision/manual hooks require no new file reads.

The supported contract requires stable inputs during preparation. Checks at these boundaries do not provide a filesystem transaction, detect a change that is reverted between checks, or freeze shared libraries/remote services. Document that limitation explicitly; do not promise arbitrary process hermeticity. A change detected during build-time hook checks must prevent publication. A change detected only by the final result check returns an error without handing out the baseline; do not delete a published/shared generation to hide the race. Later preparations recompute identity from current inputs.

Use phase `hook-revision` and stable operational codes `hook_revision_input_unreadable` and `hook_revision_inputs_changed` with exit 1; malformed/conflicting declarations are configuration-resolution errors with exit 4. It is acceptable for an existing library build failure to retain its safe baseline phase while recording a specific revision-input cause through per-call captured error state. Preserve the original hook/cleanup failure if it already failed, rather than overwriting it with a later check. Add optional safe revision mode/format and logical names to preparation reports if needed, keeping `formatVersion: 1`; never print individual file contents, input values, machine paths, or raw filesystem exceptions. Do not hash secrets into a public identity and imply that hashing protects them. Secret-controlled effects require an appropriate caller-managed revision rather than `revision_values`.

Extend `scripts/test-cli.sh` for schema, omission, whole-array YAML replacement/clearing, scalar environment/override precedence, rejection of scalar array overrides, valid selection, conflicts, malformed entries, sensitive explanations, and informational paths that do no input I/O. Extend `scripts/test-cli-postgres.sh` for the representative migration driver that reads external SQL: initial `Built`, unchanged `Reused`, SQL changed with identical executable bytes gives `Built`, then unchanged `Reused`. Verify actual schema effects in an acquired clone. Add negative cases after a ready baseline already exists, with hook invocation markers proving neither hook ran on initial missing/unreadable-input failure. Test both missing-revision cases, both manual revisions, mixed manual/derived hooks, changed verification-only inputs, and observed file mutation during a hook. Preserve all existing CLI and lifecycle tests.


### Milestone 3: Exercise all declared input classes in a service example


Extend the existing Keiro service example to use derived revisions instead of a shell-computed manual executable hash. In `scripts/example-keiro.sh`, remove the ordinary manual revision exports for this path and build a temporary YAML overlay with absolute executable locations plus the selected input arrays. Remove and unset the migration/verification executable and manual-revision environment bindings so they cannot override the generated overlay; set or clear the new executable-selection environment bindings consistently as well. In particular, `HINAGATA_VERIFICATION_EXECUTABLE` must not keep pointing at the migration binary when YAML selects `verify.sh`. Apply the overlay after `examples/keiro-service/hinagata.yaml` on every example CLI invocation, including HTTP suites, startup-failure, and cancellation cases. Clear the inherited verification `argv: [verify]` with `argv: []` for the wrapper. Keep a separate manual-revision regression case in CLI integration tests. The existing immutable workbench revision and runtime dependency versions need no change.

Make application SQL an actual external input at `examples/keiro-service/migration/application.sql`, replacing only the example's embedded application SQL in `examples/keiro-service/migration/Main.hs`; upstream runtime migrations remain composed through their public APIs. Add `examples/keiro-service/migration/manifest.json` declaring the example migration ID and relative SQL file, and a service-owned verification program at `examples/keiro-service/migration/verify.sh` that invokes the built verifier and executes `examples/keiro-service/migration/verify.sql` against the managed setup endpoint. The manifest is consumed by the migration executable and the verification SQL by the verification program, not merely hashed as unused demonstration files. Validate manifest fields with safe errors and resolve its SQL path relative to its own directory.

Use service-owned environment names `EXAMPLE_MIGRATION_MANIFEST`, `EXAMPLE_VERIFY_BINARY`, and `EXAMPLE_SCHEMA_MARKER` in the explicit hook overlays. The migration executable reads the manifest and marker for both `up` and `verify`; the wrapper invokes `EXAMPLE_VERIFY_BINARY` with `verify` and then runs its sibling `verify.sql`. Derive each declared path/value and its command overlay from the same driver variable. Include application SQL and manifest in both hooks' input lists because verification recomputes the migration plan. Add a regression where only the verification SQL check is made to fail: preparation must fail, proving the wrapper actually ran instead of being bypassed by the old executable binding.

Include the built migration executable, external application SQL, manifest, verification script/SQL, and a selected non-secret schema-marker value in the relevant revision declarations. Keep migration and verification selections separately named. Pass the schema marker to the service-owned migration and verification commands through their explicit environment overlays, and also declare that same value for identity. Generate both from the same driver variable so the example does not independently duplicate two values that can drift. Let this option affect a schema comment that verification reads; quote it safely in SQL. It must not fabricate event, outbox, or workflow rows. A verification-only change must alter verification identity without requiring migration executable changes.

Use temporary copies under the example driver workspace for invalidation variants. For each input class, establish an unchanged `Reused` result, modify only that declared class, assert `Built`, then assert `Reused` on a repeat. An executable-byte variant can append an inert trailing byte to a temporary copy where supported by the platform; otherwise rebuild the same driver with a harmless changed version literal and assert the binary digest differs. Do not overwrite a live binary or edit upstream runtime code. Keep fixture bytes and baseline role settings fixed during each comparison, and retain original bytes so independent variants start from a known baseline.

For SQL, manifest, and schema-marker variants, query a fresh application-accessible clone for the expected schema/data contract or use setup access in the test driver for metadata that is deliberately privileged. The SQL change must occur while the selected executable digest stays equal. Code and manifest changes may be behavior-preserving but must still change the selected revision. Existing HTTP health/reference tests, role separation, startup failure, and cancellation behavior must still pass through the normal example path. No new HTTP service or projection worker is required.

Add new example files to `examples/keiro-service/hinagata-keiro-example.cabal` and its archive declarations. If manifest parsing needs Aeson in the migration component, reuse the repository's already established dependency cohort after checking the source API; do not widen versions opportunistically. Update `scripts/release-check.sh` to assert the new migration/verification artifacts are present and usable from the unpacked package, with no developer checkout paths. `nix develop -c just example-keiro` proves the service integration milestone.


### Milestone 4: Document boundaries and finish acceptance


Update `docs/user/configuration.md`, `docs/user/cli.md`, `docs/guides/integrate-service.md`, `docs/cli.md`, `docs/terminology/hook-revision.md`, `docs/integration.md`, and `examples/keiro-service/README.md`. Define the versioned encoding and logical names, relative-path resolution, executable selection, secret handling, literal-value declaration, precedence/conflict rules, and failure timing. Explain what is excluded: undeclared argv/environment/cwd effects, shared-library changes unless covered by selected executable/other inputs, remote state, and arbitrary service behavior. A file manifest's transitive references are not automatically discovered; list every relevant file. Changing a raw input's comments/formatting changes its bytes and therefore its revision.

Show the external-SQL case where the executable is unchanged, and show manual revision fallback for remote or otherwise unrepresentable effects. Callers may declare a non-secret identifier for a remote deployment/configuration version, but the tool cannot verify the remote state's correspondence. State that `--check-config` validates declarations while operational baseline preparation reads input contents. Amend ADR 1 and ADR 3 to accept truthful derived identities alongside explicit ones without weakening missing-revision behavior. Update generated timestamps and bundle logs for all changed profiled documents.

When implementation begins, change IR-2 to `in-progress` and update its generated timestamp and log. At completion, record concise results for AC-1 through AC-5 here, then set IR-2 to `completed`, add `completedAt` and an evidence-bearing `resolution`, and preserve its `targetPlan` and original review entries. Keep unrelated requests and external adoption work unchanged. Run strict request validation after metadata changes. Planning and author self-assessment do not count as independent implementation approval.


## Concrete Steps


Run commands from the repository root. Use the existing development shell for GHC/Cabal, PostgreSQL, Hurl, Dhall, OKF, and Just. Leave externally supplied `HINAGATA_TEST_PG*` endpoints unset so database wrappers allocate and clean up a disposable local cluster.

For the deterministic helper and offline declaration milestone checks:

```bash
nix develop -c just core-test
nix develop -c just test-cli
```

Expected results: the core test suite passes the known-answer, relocation, ordering, and input-failure cases; the CLI script prints `CLI offline smoke test passed`. Offline checks must not run a migration or open PostgreSQL, and schema/help/explanation paths must not read declared content files.

For the native cache interaction and service example:

```bash
nix develop -c just test-cli-postgres
nix develop -c just example-keiro
```

Expected observations for one selected input mutation are:

```text
original inputs: Built
same inputs: Reused
one declared input changed: Built
same changed inputs: Reused
```

Use a complete normal Hinagata configuration plus a fragment such as this, with paths replaced for the service workspace:

```yaml
migration:
  executable: /absolute/path/to/hinagata-keiro-migrate
  argv: [up]
  cwd: /absolute/path/to/service-workspace
  environment:
    - EXAMPLE_MIGRATION_MANIFEST=migration/manifest.json
    - EXAMPLE_SCHEMA_MARKER=example-v1
  revision_executable: true
  revision_inputs:
    - application/sql=migration/application.sql
    - application/manifest=migration/manifest.json
  revision_values:
    - schema-marker=example-v1
verification:
  executable: /absolute/path/to/service-workspace/migration/verify.sh
  argv: []
  cwd: /absolute/path/to/service-workspace
  environment:
    - EXAMPLE_MIGRATION_MANIFEST=migration/manifest.json
    - EXAMPLE_VERIFY_BINARY=/absolute/path/to/hinagata-keiro-migrate
    - EXAMPLE_SCHEMA_MARKER=example-v1
  revision_executable: true
  revision_inputs:
    - application/sql=migration/application.sql
    - application/manifest=migration/manifest.json
    - verification/program=/absolute/path/to/hinagata-keiro-migrate
    - verification/sql=migration/verify.sql
  revision_values:
    - schema-marker=example-v1
```

Both hooks must actually read the declared paths/values through their argv/environment configuration, supplied by the example driver; declaring them alone does not pass them to the command. In this fragment each hook needs the correct cwd for its relative inputs. Set no manual `revision` in derived mode. The original manual setting remains valid on its own:

```yaml
migration:
  executable: /absolute/path/to/service-migrate
  revision: service-schema-v12
```

On the final candidate, retain applicable passing results above and run the remaining relevant checks once:

```bash
nix develop -c just test-postgres
nix develop -c just example-workbench
nix develop -c just check-conventions
nix develop -c just check-docs
nix develop -c just fmt-check
nix develop -c just release-check
```

Record concise acceptance evidence rather than full routine transcripts. For request metadata alone, use the focused gate:

```bash
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

Use Conventional Commits on the current branch unless the user requests another branch. Implementation commits carry `ExecPlan: docs/plans/7-derive-baseline-hook-revisions-from-declared-content-inputs.md` and the `Intention:` trailer from this plan's frontmatter.


## Validation and Acceptance


AC-1 is satisfied by fixed format vectors plus equivalent named files/values in different temporary roots. Reorder declarations and modify file timestamps without changing bytes: the revision must be equal. Change bytes, logical names, or values: it must differ. The encoding must distinguish boundary-ambiguous concatenations. No physical path, timestamp, permission, or input enumeration order may enter the derived revision.

AC-2 is satisfied by real PostgreSQL preparation and the service example. Independently change selected executable bytes, application SQL, migration manifest, verification code/SQL, and consumed non-secret configuration after a `Reused` call. Each selected change must lead to `Built`, and a repeat must yield `Reused`. Inspect the expected database effect where the input changes behavior. In the external-SQL case assert the executable digest did not change. Both migration and verification derivation paths must be exercised.

AC-3 is satisfied by missing/unreadable selected inputs both before a first build and after a matching ready baseline exists. Every initial capture failure must precede `ensureBaseline` and produce zero hook invocations. Add deletion/change during build and simulated lock waiting to check revalidation and refusal of a stale result. Test sensitive sentinels in file contents, literal settings, and malformed entries; configuration explanations and operational errors must omit those sentinels. New revision explanations and errors must omit physical input paths. For configuration explanations, place a unique private path only in `revision_inputs` and assert its absence, while preserving the existing visibility of public executable/cwd/fixture-root settings. Do not assert that a full configuration explanation hides every absolute path. Child-owned output is not copied into revision diagnostics. Test unreadability with real permission boundaries rather than assuming `chmod 000` fails for a privileged test process.

AC-4 is satisfied by existing explicit revisions yielding `Built` then `Reused`, either missing revision forcing repeated builds, mixed manual/derived hooks working, and conflicting explicit/derived settings failing offline with exit 4. Direct Haskell users can keep supplying `Maybe Text` revisions unchanged. No inputs are read for legacy manual/no-revision preparation. Clone preparation remains excluded if ExecPlan 6 has been implemented.

AC-5 is satisfied by references and the runnable service example explicitly covering an external SQL change without executable changes and the limits of declared dependencies. The example must consume the listed inputs and selected configuration. Document manual fallback for remote/secret-controlled effects and concurrent mutation limitations. Source archives must contain the helper, example SQL/manifest/verification files, and required package declarations.

The first producer/consumer proof is the CLI migration driver reading external SQL in Milestone 2; run it before expanding service variants. There is no requirement to change baseline schema/catalog, infer dependencies, compare live schemas, add Linux CI, introduce a standalone revision subcommand, or benchmark hashing performance for acceptance.


## Idempotence and Recovery


The helper only reads caller-selected inputs and produces an identity; it must not edit them, execute commands, or write a cache beside them. Recompute contents on each operational preparation, even when the database baseline is likely reusable. Use temporary directories for test mutations and restore them by discarding the isolated workspace. Never mutate a developer's source SQL or a running binary to test invalidation.

Detected input changes require a fresh preparation from a stable set, not an automatic retry that could hide edits. Existing lifecycle failure/cleanup rules apply to a failed build. A final revalidation failure may leave an owned generation available for later inspection/reuse under its recorded identity; never delete a shared generation based solely on changed source files. Recompute identity on the next attempt and retain positive ownership checks for explicit database cleanup.

Logical-name renames deliberately invalidate a derived revision. Moving files with the same logical names and bytes does not. Switching from manual to derived mode can build a new generation because revision strings differ; old generations remain managed normally. To revert the authoring mode, remove all derived selectors and provide a truthful manual revision, or omit revisions and accept rebuilding. Do not fill in a placeholder revision just to enable reuse.


## Interfaces and Dependencies


The reusable module is `Hinagata.Hook.Revision` in `hinagata-core`. Its named input constructors, opaque captured evidence, derived revision accessor, and verification operation must be usable by direct Haskell callers without Settei or a subprocess dependency. Preserve the existing `BaselineSpec` revision interface. Keep physical locations and values out of public diagnostic rendering.

The CLI adds per-hook `revision_executable`, `revision_inputs`, and `revision_values`, with absence selecting existing behavior. `Hinagata.Cli.Revision` adapts these declarations to the helper and returns safe `CliError` outcomes. Input capture belongs before `ensureBaseline`; build/reuse revalidation belongs in that preparation call and its wrapped hook callbacks. The example's domain migration/verification code remains service-owned.

Reuse `mori://haskell-hvr/cryptohash-sha256/packages/cryptohash-sha256` through the core package's existing direct dependency, and `mori://shinzui/settei/packages/settei` with its current adapters. Mori discovery found the incremental hash API and Settei's secret setting/list/Boolean decoder APIs in their registered sources. Use `mori registry search`, `mori registry show --full`, and `mori registry docs` before relying on further dependency APIs. No dependency upgrade or pin change is planned. If a direct dependency is added to a component or bounds change, verify current authoritative registry releases and upstream tags before selecting bounds; local registry metadata alone is insufficient. Never inspect `/nix/store` for source.

[ExecPlan 6](6-expose-clone-preparation-hooks-through-the-cli.md) may change the shared `HookSettings` representation. Preserve its separation of clone-command settings from baseline revision settings whichever plan runs first. Neither plan blocks the other, and this work must not add derived identity to per-clone seeding. This plan has no parent MasterPlan and no dependency on external adoption completion.

Revision note (2026-10-18): Reviewed against the CLI, baseline lifecycle, example driver, ADRs, and Mori-located dependency sources. Corrected environment precedence that would bypass the example verifier; made shared verifier inputs and their command wiring explicit; specified scalar versus array overrides and the offline validation boundary; and scoped redaction acceptance to the new sensitive inputs. AC-1 through AC-5 and the four implementation milestones remain unchanged. The external origin MasterPlan exists in its registered checkout, although `mori path` currently cannot resolve that artifact; its canonical URI is retained.
