# Hinagata CLI

Start with the [user documentation](user/README.md) for task-based instructions.
See the new [command reference](user/cli.md) and [configuration reference](user/configuration.md).

Use `nix develop` in the repository root. The development shell comes from `mori://shinzui/seihou-modules/templates/nix-haskell-flake`; it supplies GHC, Cabal, PostgreSQL tools, Hurl, and Dhall. `cabal run hinagata -- --help` shows the command grammar. Help, version, completion scripts, and `--describe-config-json` work without a config file or PostgreSQL server.

Configuration sources are applied in this order: built-in Settei defaults, repeated `--config FILE` YAML files in argument order, explicit `HINAGATA_*` environment bindings, and repeated `--set KEY=VALUE` overrides. `--check-config` and `--explain-config` resolve settings without connecting to PostgreSQL. Password settings and hook `argv`/`environment` values are redacted in explanations. Endpoint, project, maintenance database, three explicit role/database selections, and absolute fixture and bundle roots are required for operational commands. The [workbench example](../examples/workbench/README.md) sets its machine-specific paths and disposable socket through environment bindings over a checked-in YAML file.

```bash
cabal run hinagata -- --config path/to/hinagata.yaml fixture plan seeded-member --json
cabal run hinagata -- --config path/to/hinagata.yaml fixture load seeded-member --target-database my_test_db --json
cabal run hinagata -- --config path/to/hinagata.yaml fixture validate seeded-member --json
cabal run hinagata -- --config path/to/hinagata.yaml fixture validate --all --json
```

`fixture plan` compiles frozen source bytes and stays offline; it does not claim a database cache hit. `fixture load` writes to the existing, caller-owned database named by `--target-database` and never takes deletion authority over it. Repeating it may conflict with rows already present. `fixture validate` tests each named scenario in a separate clone with bounded manager admission. `--all` discovers fixture directories in sorted order. JSON results stay in selection order even when setup workers run concurrently.

`db prepare` builds or reuses a sealed baseline. `baseline.fixtures` is the YAML list of base fixtures. The `migration` and `verification` settings each accept `executable`, `argv` (a YAML array), `cwd` (an absolute directory), `environment` (a YAML array of `NAME=VALUE` entries), `revision`, and positive `deadline_ms`. Executables receive the setup endpoint through `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE`, with an optional private `PGPASSFILE`; they must close their connections before exiting. A revision without its executable is rejected. If either revision is absent, persistent baseline reuse is disabled. A command path alone never authorizes reuse. Hook execution has a deadline and invokes argv directly without a shell.

```bash
cabal run hinagata -- --config path/to/hinagata.yaml db prepare --json
cabal run hinagata -- --config path/to/hinagata.yaml db acquire --fixture seeded-member --json
cabal run hinagata -- --config path/to/hinagata.yaml inspect LEASE_ID --json
cabal run hinagata -- --config path/to/hinagata.yaml db release LEASE_ID --json
cabal run hinagata -- --config path/to/hinagata.yaml db with --fixture seeded-member -- PROGRAM ARGS...
```

`db acquire` leaves a detached database for a separate process; its JSON gives safe endpoint fields and lease/run IDs, never credentials. `db release` rechecks ownership and is idempotent. `db with` holds a scoped lease while one generic command runs. It passes the application role only: the managed child overlay is `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `HINAGATA_RUN_ID`, and `HINAGATA_LEASE_ID`. Ambient `PG*` and `HINAGATA_*` values are removed first. When the application role has a password, Hinagata creates a mode-0600 `PGPASSFILE` for the child and removes it after reaping. No environment variable carries the password. The child has `/dev/null` stdin and its own POSIX process group. SIGINT/SIGTERM are forwarded, followed by bounded TERM→KILL cleanup. If that group cannot be proven stopped, the lease is preserved for inspection.

The child’s failing exit status is returned unchanged; a subsequent database cleanup problem is reported separately. A successful child followed by cleanup failure exits 1. `--preserve-on-failure` keeps a failed command’s lease until explicit release. With `--json`, child stdout is sent to stderr so stdout remains one versioned JSON document.

```bash
cabal run hinagata -- --config path/to/hinagata.yaml clean --json
cabal run hinagata -- --config path/to/hinagata.yaml clean --apply --id ALLOCATION_ID --json
cabal run hinagata -- --config path/to/hinagata.yaml clean --apply --include-retained --id ALLOCATION_ID --json
```

`clean` previews candidates by default. Apply requires selected allocation IDs and revalidates each candidate before removal. Retained databases require `--include-retained` and an explicit ID. Ambiguous or foreign identities are refused. `inspect LEASE_ID` reports lifecycle state and current classification, including released records.

JSON responses use `formatVersion: 1`, `ok`, and a command `kind` or stable `error.code`, with phase, fixture/step, SQLSTATE, and safe target context when available. Usage errors exit 2, configuration source errors 3, resolution errors 4, and operational errors 1. `db with` returns the child's nonzero status, including cancellation codes 130/143. Diagnostics are written to stderr when JSON is selected.

`just test-cli` is offline. `just test-cli-postgres` and `just example-workbench` each start and stop their own disposable socket cluster; neither targets an external PostgreSQL server.
