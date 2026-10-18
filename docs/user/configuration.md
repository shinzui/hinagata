---
type: Reference
title: "Configuration reference"
description: "Set explicit database connections, fixture paths, hooks, and operational limits."
docId: DOC-3
tags: ["configuration", "access"]
generated:
  by: process:codex
  at: 2026-10-18T19:08:35Z
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
The [first-use tutorial](getting-started.md) contains a complete offline configuration.
For database operations, supply existing roles and databases that permit the required operations.

## Environment variables

Core bindings use the `HINAGATA_` prefix and uppercase setting names.
Replace dots with underscores.
For example, `fixture.root` becomes `HINAGATA_FIXTURE_ROOT`.

CLI hook bindings cover `executable`, `cwd`, `revision`, and `deadline_ms` for `migration` and `verification`.
Use YAML for `baseline.fixtures`, hook `argv`, and hook `environment` arrays.
These arrays have no environment binding.
Clone preparation binds its scalar settings to `HINAGATA_CLONE_PREPARATION_EXECUTABLE`,
`HINAGATA_CLONE_PREPARATION_CWD`, and `HINAGATA_CLONE_PREPARATION_DEADLINE_MS`.

```sh
cabal run hinagata -- --config CONFIG --check-config
cabal run hinagata -- --config CONFIG --set limits.active_leases=4 --explain-config
```

Configuration explanations hide passwords, hook arguments, and hook environment values.
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
| `revision` | Identity of the program's effects. |
| `deadline_ms` | Positive execution limit; default `300000` milliseconds. |

Hooks receive the setup connection through PostgreSQL environment variables.
Close all hook connections before the program exits.
A revision requires an executable.
If either revision is absent, Hinagata builds a new baseline on each preparation.
A program path alone does not establish a reusable revision.
Change the revision when the hook's effects change.

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

The record accepts the baseline hook command keys above except `revision`.
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
Service migrations must supply required table and sequence grants.

For the complete machine-readable declaration, run:

```sh
cabal run hinagata -- --describe-config-json
```
