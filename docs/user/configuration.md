---
type: Reference
title: "Configuration reference"
description: "Set explicit database connections, fixture paths, hooks, and operational limits."
docId: DOC-3
tags: ["configuration", "access"]
generated:
  by: process:codex
  at: 2026-10-02T16:49:46Z
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
