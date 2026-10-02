---
type: Reference
title: "Command reference"
description: "Find command syntax, process behavior, JSON output, and exit codes."
docId: DOC-2
tags: ["cli", "operations"]
generated:
  by: process:codex
  at: 2026-10-02T16:49:46Z
---

# Command reference

Run these commands from the repository root in `nix develop`.
Replace uppercase placeholders with your values.
`CONFIG` is the path to your YAML configuration file.

## Offline commands

```sh
cabal run hinagata -- --help
cabal run hinagata -- --version
cabal run hinagata -- --describe-config-json
cabal run hinagata -- completions bash
cabal run hinagata -- --config CONFIG --check-config
cabal run hinagata -- --config CONFIG --explain-config
cabal run hinagata -- --config CONFIG fixture plan NAME --json
```

Help, version, completions, and configuration descriptions need no configuration file.
Configuration checks and fixture plans need [valid settings](configuration.md).
They do not connect to PostgreSQL.
A fixture plan captures files into a [fixture bundle](../terminology/fixture-bundle.md).
It does not prove that SQL will succeed.

## Fixture commands

```sh
cabal run hinagata -- --config CONFIG fixture load NAME --target-database DATABASE --json
cabal run hinagata -- --config CONFIG fixture validate NAME --json
cabal run hinagata -- --config CONFIG fixture validate --all --json
```

`plan` and `load` accept one or more fixture names.
`load` writes to the existing database that `--target-database` selects.
It does not give Hinagata permission to delete that database.
A repeated load can fail because rows already exist.

`validate` tests each scenario in a separate clone.
Use either explicit names or `--all`.
`--all` finds fixture directories in sorted order.
Results keep the selection order when workers run concurrently.

## Database commands

```sh
cabal run hinagata -- --config CONFIG db prepare --json
cabal run hinagata -- --config CONFIG db acquire --fixture NAME --json
cabal run hinagata -- --config CONFIG db with --fixture NAME -- PROGRAM ARGS...
cabal run hinagata -- --config CONFIG inspect LEASE_ID --json
cabal run hinagata -- --config CONFIG db release LEASE_ID --json
```

`prepare` builds or reuses a sealed baseline.
`acquire` leaves a detached lease for a separate process.
`with` runs one child command with a lease.
Repeat `--fixture NAME` to select more than one scenario fixture.
`release` uses a lease ID and checks database ownership again.

The child receives the application connection through `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE`.
It also receives `HINAGATA_RUN_ID` and `HINAGATA_LEASE_ID`.
Hinagata removes inherited `PG*` and `HINAGATA_*` variables before it sets this environment.

If a password is necessary, Hinagata supplies a private `PGPASSFILE` with mode `0600`.
Hinagata removes the file after the child stops.
The child receives no password value through an environment variable.
Its standard input is `/dev/null`.

Hinagata starts the child in a separate POSIX process group.
It sends cancellation signals to that group and bounds the time to stop it.
If Hinagata cannot establish that the group stopped, it preserves the clone.

Use `--preserve-on-failure` before `--` to keep a failed command's database.
With `--json`, child output goes to standard error.
Standard output contains one JSON document.

## Cleanup commands

```sh
cabal run hinagata -- --config CONFIG clean --json
cabal run hinagata -- --config CONFIG clean --apply --id ALLOCATION_ID --json
cabal run hinagata -- --config CONFIG clean --apply --include-retained --id ALLOCATION_ID --json
```

`clean` only shows a preview unless you specify `--apply`.
Apply also needs an explicit allocation ID.
Retained databases need `--include-retained`.
See [Inspect and release databases](../guides/manage-leases.md) before cleanup.

## Reports and exit codes

JSON reports contain `formatVersion: 1` and `ok`.
Successful reports identify the command through `kind`.
Errors contain a stable `error.code`.
Available context includes the phase, fixture, step, SQLSTATE, and safe connection fields.
Reports omit credentials.

| Exit code | Meaning |
| --- | --- |
| `0` | The command succeeded. |
| `1` | An operation failed. |
| `2` | The command syntax or selection is invalid. |
| `3` | A configuration source failed. |
| `4` | Configuration resolution failed. |

`db with` returns a failed child's exit code, including cancellation codes `130` and `143`.
A later cleanup failure does not replace that code.
If the child succeeds but cleanup fails, Hinagata returns `1`.
The report keeps child failure and cleanup failure separate.
