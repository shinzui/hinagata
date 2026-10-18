---
type: Reference
title: "Configuration reference"
description: "Set explicit database connections, fixture paths, hooks, and operational limits."
docId: DOC-3
tags: ["configuration", "access"]
generated:
  by: process:codex
  at: 2026-10-18T19:46:53Z
---

# Configuration reference

Hinagata uses Settei for configuration: `mori://shinzui/settei`.
Later sources override earlier sources in this order:

1. Built-in defaults.
2. YAML files, in `--config` argument order.
3. Explicit environment bindings.
4. Overrides, in `--set KEY=VALUE` argument order.

## Required settings

| Key | Value |
| --- | --- |
| `endpoint.host` | An absolute socket directory or an explicit TCP hostname. |
| `endpoint.port` | A port from `1` through `65535`. |
| `project.id` | A valid lowercase project ID. |
| `fixture.root` | An absolute directory for fixture sources. |
| `bundle.root` | An absolute directory for private fixture bundles. |
| `maintenance.database` | An existing database for the maintenance catalog. |
| `administration.user`, `administration.database` | Explicit administration role and database. |
| `setup.user`, `setup.database` | Explicit setup role and database. |
| `application.user`, `application.database` | Explicit application role and database. |

Each role can also have an optional `password` setting.
The three database selections have no fallback.
Native connections and rendered connection strings use the explicit host, port, user, and database.
An explicit empty `hostaddr` prevents `PGHOSTADDR` or service-file address defaults from redirecting the host.
Other libpq defaults, including password/passfile and TLS settings, remain available.
The [first-use tutorial](getting-started.md) contains a complete offline configuration.
For database operations, supply existing roles and databases that permit the required operations.

## Environment variables

Core bindings use the `HINAGATA_` prefix and uppercase setting names.
Replace dots with underscores.
For example, `fixture.root` becomes `HINAGATA_FIXTURE_ROOT`.

CLI hook bindings cover `executable`, `cwd`, `revision`, `revision_executable`, and `deadline_ms` for `migration` and `verification`.
Use YAML for `baseline.fixtures`, hook `argv`, hook `environment`, `revision_inputs`, and `revision_values` arrays.
These arrays have no environment binding.
Clone preparation binds its scalar settings to `HINAGATA_CLONE_PREPARATION_EXECUTABLE`,
`HINAGATA_CLONE_PREPARATION_CWD`, and `HINAGATA_CLONE_PREPARATION_DEADLINE_MS`.

```sh
cabal run hinagata -- --config CONFIG --check-config
cabal run hinagata -- --config CONFIG --set limits.active_leases=4 --explain-config
```

Configuration explanations hide passwords, hook arguments, hook environment values, and revision input/value arrays.
Do not put passwords in shell command arguments.

## Baseline hooks

`baseline.fixtures` lists the fixtures that belong in each baseline.
The `migration` and `verification` records accept these keys:

| Key | Meaning |
| --- | --- |
| `executable` | Program to run with setup access. |
| `argv` | YAML array of arguments, without shell evaluation. |
| `cwd` | Absolute working directory. |
| `environment` | YAML array of `NAME=VALUE` entries. |
| `revision` | Caller-managed identity of the program's effects. |
| `revision_executable` | Select executable bytes; Boolean, default `false`. Requires an absolute executable. |
| `revision_inputs` | YAML array of named `NAME=PATH` file inputs; default `[]`. |
| `revision_values` | YAML array of named `NAME=VALUE` non-secret literal inputs; default `[]`. |
| `deadline_ms` | Positive execution limit; default `300000` milliseconds. |

Hooks receive the setup connection through PostgreSQL environment variables.
Close all hook connections before the program exits.
A revision requires an executable.
If either hook has neither a manual nor a derived revision, Hinagata builds a new baseline on each preparation.
A program path alone does not establish a reusable revision.
Change the revision when the hook's effects change.

## Content-derived baseline revisions

Declare the complete set of files and non-secret values that determine each hook's effects.
For example, layer this fragment over complete database/fixture settings:

```yaml
migration:
  executable: /absolute/service/migrate
  argv: [up]
  cwd: /absolute/service
  environment: ["SERVICE_SQL=migration/application.sql", "SERVICE_MODE=test-v1"]
  revision_executable: true
  revision_inputs: ["application/sql=migration/application.sql"]
  revision_values: ["mode=test-v1"]
verification:
  executable: /absolute/service/verify
  cwd: /absolute/service
  revision_executable: true
  revision_inputs: ["application/sql=migration/application.sql", "verification/sql=migration/verify.sql"]
```

The service commands must actually consume the declared files/values through their own arguments or environment.
A declaration identifies content; it does not pass it to the command.
Generate each selected value and its command overlay from the same source variable.
Editing external `application.sql` selects a new baseline even when `migrate` has identical bytes.
See the runnable [Keiro example](../../examples/keiro-service/README.md), which also consumes a manifest and a schema-marker value.

Names start with a lowercase ASCII letter and use only lowercase letters, digits, `.`, `_`, `-`, and `/`.
Slash components cannot be empty, `.` or `..`. Names are unique across files and values.
Executable selection contributes a file named `executable`, so another input cannot use that name when selected.
Entries split at the first `=`; paths and values may contain further equals signs.
Paths must be nonempty and contain no NUL. Empty literal values are valid.
Relative paths resolve against the hook's absolute `cwd`, or the invocation directory captured once when cwd is omitted.
The YAML file's directory is never the input root.
Symlinks to regular files are allowed; targets are read and rechecked. Directories, pipes, and other streams are rejected.
Executable permission is excluded from identity; process startup still requires an executable command.
Basename commands remain supported when executable bytes are not selected.

Any effective selector chooses derived mode. Setting a manual `revision`, even an empty string, together with a selector is a configuration error.
Empty arrays and `revision_executable: false` select no content; manual/omitted revision behavior then applies.
Later YAML arrays replace earlier arrays as a whole; `[]` clears an array.
Scalar environment bindings `HINAGATA_MIGRATION_REVISION_EXECUTABLE` and `HINAGATA_VERIFICATION_REVISION_EXECUTABLE` override YAML.
Repeated scalar `--set` overrides beat environment bindings.
Arrays require YAML; `--set migration.revision_inputs=[]` is a type error, not an array clear.
To return to manual mode, clear both arrays and disable executable selection in a later YAML layer, then set `revision`.
Clone preparation has none of these revision selectors and remains outside baseline identity.

`--check-config` validates names, entries, modes, executable requirements, and duplicates offline without reading selected files.
Configuration explanations also perform these checks and redact the input/value arrays.
Operational `db prepare`, `db acquire`, `db with`, and `fixture validate` capture both hooks' selected contents before baseline preparation.
An unreadable input fails before reuse or either hook runs, with phase `hook-revision`, code `hook_revision_input_unreadable`, and exit `1`.
Malformed/conflicting declarations fail resolution with exit `4`.
Both captured sets are checked before and after each successful build-time hook and after the build/reuse result, including after lock waiting.
Detected changes return `hook_revision_inputs_changed` with exit `1`; an original hook failure keeps its original cause.
Revision diagnostics contain only safe hook/logical labels, never selected file bytes, literal values, physical paths, or raw filesystem exceptions.
Child-owned stderr remains the command's responsibility.

Keep selected inputs stable throughout preparation. Boundary checks do not provide a filesystem transaction, freeze arbitrary process dependencies, or detect a change reverted between checks.
Changes detected around hooks prevent publication; a change detected only after publication returns an error without handing out the result.
That final error does not delete a shared generation. Start a fresh preparation from stable inputs.

Only declared content contributes to this identity. A manifest's referenced files are not discovered transitively: list every file.
Undeclared argv/environment/cwd effects, shared libraries, remote services, and other process behavior remain caller-owned.
Raw byte changes, including comments, newlines, and formatting, invalidate identity. No SQL/JSON semantic equivalence is inferred.
Use a truthful manual `revision` for remote or secret-controlled effects that cannot be represented by selected content.
A non-secret remote deployment/version identifier may be a declared value, but Hinagata cannot verify that it matches remote state.
Never select secrets as file contents or literal values; hashing does not protect a secret in a public identity.

### Version-1 encoding

The reusable `Hinagata.Hook.Revision` helper accepts a nonempty list of `FileInput` and `ValueInput` entries with smart-constructed `InputName` values.
`deriveHookRevision` returns opaque evidence, `hookRevision` returns its revision, and `verifyHookRevisionInputs` checks the selected files again.
`revisionInputLabels` exposes only safe names and kinds. Direct callers pass the derived text through the existing `Maybe Text` baseline revision fields and own the same execution-boundary checks.

The printable format is `hinagata-hook-revision-v1:sha256:` plus 64 lowercase hexadecimal digits.
Hash an encoding beginning with UTF-8 `hinagata-hook-revision-v1` and a zero byte, followed by the entry count.
Sort entries by the UTF-8 bytes of the logical name. Encode each name's byte length followed by its bytes, then a one-byte kind tag (`1` file, `2` value).
File payloads are the byte count followed by 32 raw SHA-256 digest bytes; values are their UTF-8 byte length followed by exact UTF-8 bytes.
All lengths/counts are unsigned 64-bit big-endian integers.
File lengths are counted from the same bytes fed to the incremental hash, with bounded read memory.
Physical paths, mtimes, access times, inode numbers, permissions, and declaration order are excluded; logical name and kind changes are included.

## Per-clone preparation

Use `clone.preparation` to seed domain state through a service-owned command before startup.
Layer this fragment over a complete configuration; replace the paths with existing executables and directories:

```yaml
clone:
  preparation:
    executable: /absolute/path/to/hinagata-keiro-seed
    argv: [seeded, "2"]
    cwd: /absolute/path/to/service-workspace
    environment: []
    deadline_ms: "10000"
```

The record accepts only `executable`, `argv`, `cwd`, `environment`, and `deadline_ms`.
Changing the executable, arguments, or other preparation settings leaves an unchanged baseline reusable.
The command runs once on each new clone, including clones of a reused baseline.
It runs after clone access is configured, before the scenario suffix loads, and before application handoff.
`db acquire`, `db with`, and each `fixture validate` acquisition invoke it.
`db prepare`, offline diagnostics/planning, and direct `fixture load` do not invoke it.

Omit the executable, argv, cwd, and environment to disable preparation.
A deadline alone is harmless; other settings without an executable are invalid.
Executables must be nonempty and executable/argv/cwd/environment values cannot contain NUL.
The working directory must be absolute, and environment entries must be valid `NAME=VALUE` pairs.
Overlays cannot replace managed `PG*` or `HINAGATA_*` variables.
`--check-config` rejects invalid combinations offline.

The default deadline is `300000` milliseconds; a configured deadline must be positive.
The remaining `limits.acquisition_deadline_ms` can end preparation sooner.
Both limits prevent application startup on expiry and include bounded process shutdown before safe release.
The command receives only the setup endpoint in `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE`,
plus an optional private mode-0600 `PGPASSFILE` removed after supervision ends.
Ambient `PG*` and `HINAGATA_*` variables are removed; arguments remain literal and no shell is introduced.
Arguments and environment values are redacted from explanations.
Executable output goes to stderr and is never embedded in JSON errors; the executable must protect its own output.

Use baseline fixtures for shared reference data, preparation for domain commands on each clone,
and scenario fixtures for independent test-specific data or SQL that depends on those commands.
Close all seed pools before exiting. Service startup, readiness, and projection workers remain caller-owned.
See [Integrate a service](../guides/integrate-service.md) and the [Keiro example](../../examples/keiro-service/README.md).

## Defaults

| Key | Default |
| --- | --- |
| `maintenance.schema` | `hinagata` |
| `clone.strategy` | `WAL_LOG` |
| `limits.acquisition_deadline_ms` | `30000` |
| `limits.setup_deadline_ms` | `300000` |
| `limits.setup_workers` | `2` |
| `limits.active_leases` | `8` |
| `limits.pending_requests` | `32` |
| `limits.chunk_size` | `65536` bytes |
| `limits.sql_size_limit` | `1048576` bytes |
| `setup.grants` | `CONNECT`, `CREATE`, `TEMPORARY` |
| `application.grants` | `CONNECT` |
| `setup.schema_grants` | `public:USAGE`, `public:CREATE` |
| `application.schema_grants` | `public:USAGE` |
| `setup.settings`, `application.settings` | Empty lists |

Limits apply to one manager, not to all processes on a server.
The acquisition deadline ends when Hinagata gives the clone to the consumer.
It does not limit test duration.
Use `FILE_COPY` only after measurements on your server.

Database grants accept `CONNECT`, `CREATE`, and `TEMPORARY`.
Schema grants accept `SCHEMA:USAGE` and `SCHEMA:CREATE`.
Role settings accept `NAME=VALUE` entries.
Use a YAML array for list values, for example `setup.settings: ["search_path=public,pg_catalog"]`.
PostgreSQL interprets this as two schemas; an explicitly quoted name such as `"comma,schema"` remains one schema.
Each role persists its own declaration atomically under its existing parameter permissions.
List values use PostgreSQL interpretation; scalar declarations do not change the session applying them.
Custom parameter placeholders require PostgreSQL's normal `SET` permission.

Baseline identity uses `hinagata-fingerprint-v2` for these corrected setting semantics.
Version-1 generations remain inspectable but are not reused; preparation builds a new generation and then reuses it normally.
Comparisons against version-1 manifests report `FingerprintVersion` along with any changed inputs.
This invalidation does not modify or delete old sealed databases, or change the maintenance catalog format.
Service migrations must supply required table and sequence grants.

For the complete machine-readable declaration, run:

```sh
cabal run hinagata -- --describe-config-json
```
