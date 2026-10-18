---
type: Reference
title: "Command reference"
description: "Find command syntax, process behavior, JSON output, and exit codes."
docId: DOC-2
tags: ["cli", "operations"]
generated:
  by: process:codex
  at: 2026-10-18T19:46:53Z
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
Checks validate revision declarations without reading their selected files; explanations redact revision input/value arrays.
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
One command scope owns SIGINT/SIGTERM for all concurrent children and workers.
Cancellation stops active work and prevents pending scenarios from starting.
Results retain completed scenarios and per-lease failures; unstarted selections report `command_cancelled` without lease/run IDs.
The command joins bounded child and lease cleanup before returning `130` for SIGINT or `143` for SIGTERM.
The first signal determines that status even if another scenario or cleanup also fails.

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

Configured `clone.preparation` runs with setup access after clone/access creation,
before scenario fixtures, and before the detached or application handoff.
It runs for `acquire`, `with`, and every validation clone, including reused baselines.
`prepare`, `fixture plan`, and direct `fixture load` never seed a clone.
See [Per-clone preparation](configuration.md#per-clone-preparation) for YAML, bindings, and deadlines.

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
Fixture failures also include `error.loadContext` (or a validation result's `error.loadContext`):

```json
{
  "phase": "ExecuteSql",
  "fixture": "example",
  "stepIndex": 1,
  "sqlState": "23505",
  "cause": "FatalError",
  "rollbackFailure": null
}
```

`stepIndex` is zero-based. A deferred constraint failure at `CommitLoad` can have null fixture and step.
Baseline/scenario failures keep their existing outer phase and error code (`baseline_failed` or `lease_failed`),
with the actual load phase in `loadContext`. Top-level fixture, step, and SQLSTATE also reflect that load.
`error.cleanupFailure` describes clone-release failure separately from `loadContext.rollbackFailure`.
The context is null for errors unrelated to fixture loading; a disconnect may provide no SQLSTATE.
These fields extend `formatVersion: 1`. Plain diagnostics include the actual fixture and step when known.
Raw SQL, row values, server exception text, credentials, and child arguments are excluded.

| Exit code | Meaning |
| --- | --- |
| `0` | The command succeeded. |
| `1` | An operation failed. |
| `2` | The command syntax or selection is invalid. |
| `3` | A configuration source failed. |
| `4` | Configuration resolution failed. |

SIGINT/SIGTERM interrupt native fixture loading and catalog waits as well as child commands.
Hinagata joins cleanup before returning `130`/`143`; repeated signals preserve the first signal and do not restart cancellation.
Uncommitted direct-load writes roll back. A signal after a confirmed commit cannot undo committed work.

`db with` returns a failed child's exit code, including cancellation codes `130` and `143`.
A later cleanup failure does not replace that code.
If the child succeeds but cleanup fails, Hinagata returns `1`.
The report keeps child failure and cleanup failure separate.

Preparation failures have phase `clone-preparation`, optional generated `runId` and `leaseId`,
and one of `clone_preparation_failed`, `clone_preparation_timeout`,
`clone_preparation_cancelled`, or `clone_preparation_cleanup_failed`.
Spawn and nonzero seed exits return `1`; the seed's exit status is diagnostic rather than an application exit code.
SIGINT/SIGTERM return `130`/`143` even before the application starts or when a seed handles a signal by exiting zero.
A failing or timed-out seed prevents consumer startup and releases the clone once its processes are proven stopped.
An uncertain process stop preserves the database regardless of `--preserve-on-failure`.
Establish process stoppage before explicit release; a lost ownership session leaves an inspectable orphan.
Database release failure remains separate from the preparation cause and leaves an inspectable cleanup record.


Baseline content inputs are captured for `db prepare`, `db acquire`, `db with`, and `fixture validate`, even on reuse.
The [content-derived revision reference](configuration.md#content-derived-baseline-revisions) defines selectors, precedence, paths, and the stable-input contract.
Unreadable selected inputs return phase `hook-revision`, code `hook_revision_input_unreadable`, exit `1`, before either baseline hook runs.
Detected mutation returns `hook_revision_inputs_changed` and prevents result handoff; an earlier command failure retains its cause.
These diagnostics omit selected contents, values, physical input paths, and raw filesystem errors.
Invalid/conflicting declarations return configuration exit `4` even through `--check-config`.
