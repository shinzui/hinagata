# Integrating a service

Hinagata uses PostgreSQL that the caller already runs. The service owns its migrations, schema verification, and application connection pool. Hinagata connects directly through a Unix socket or an explicitly configured TCP endpoint, builds a sealed baseline, and gives each suite a fresh clone. The development shell is bootstrapped from `mori://shinzui/seihou-modules/templates/nix-haskell-flake` and includes PostgreSQL 18, Hurl, and hurlfmt.

Run the complete consumer proof from the repository root:

```sh
nix develop -c just example-keiro
```

This starts a disposable socket-only PostgreSQL cluster, creates distinct administration, setup, and application roles, builds the [Keiro consumer](../examples/keiro-service/README.md), and runs its service through the pinned `mori://shinzui/hurl-workbench` revision. The service wrapper maps `db with`'s `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE` into service-owned Settei variables. Workbench starts the service, waits for `/health`, runs Hurl, and stops it before Hinagata releases the lease. The driver checks two concurrent read-suite leases on different ports with distinct seeded third rows, a command followed by a read through public Keiro/Kiroku APIs, a generated-ID insert, and denial of an application-role schema write.

For another service, configure separate administration, setup, and application connection selections. The administration role must be able to create and drop databases on the supplied cluster; global roles and required extensions are prerequisites. The setup role runs the service's migration and verification executables. The application role receives only declared database/schema privileges plus grants issued by service migrations. Hinagata applies database grants and role-specific settings to new generations and clones. Fixture SQL may fill application tables, but it must not forge runtime event or outbox rows. The Keiro example composes Kiroku, Keiro, and application migrations in one `pg-migrate` plan, then verifies both the migration ledger and application-owned live schema.

Place immutable base data in baseline fixtures and scenario-only changes in suite fixtures. A scenario may include a base fixture by name when its captured identity is identical: Hinagata composes the plans, confirms the shared prefix, and loads only the remainder on the clone. The example's `service-scenario` includes `reference-seed`, so the base rows occur once even though the scenario names them. It inserts explicit IDs 1–3 and advances the identity sequence; the service can then insert generated ID 4. A changed migration or verification revision, changed base fixture, server major version, or relevant role/configuration input selects a new fingerprinted generation. The example probes changed migration and fixture identities and observes `Built` after an unchanged `Reused` call.

Use `hinagata fixture plan NAME` and `fixture validate NAME` before running a suite; `fixture load NAME --database DB` targets an existing caller-owned database. The direct load is one transaction and leaves database ownership with the caller. `hinagata db prepare` builds or reuses a sealed baseline; `db with --fixture NAME -- PROGRAM` scopes a clone around one child process and supplies connection variables. `db acquire` and `db release LEASE_ID` support explicit handoff when a process cannot be nested. `inspect` and `clean` expose retained or failed allocations, with an ownership-checked preview before cleanup. The [CLI guide](cli.md) lists the configuration keys, JSON reports, retention policy, and command syntax.

Use one suite invocation per independent service instance. The default Hurl suite should contain standalone read requests; write flows require workbench's explicit mutating opt-in and must read back their effect. Check statuses and response media types on every request. Keep readiness and eventual-consistency retries bounded at the observation that needs them. A failed child command is returned as a value in the `db with` JSON report; a failed cleanup is reported separately. When investigating a failed lease, inspect its ID before applying explicit cleanup. Cancellation terminates the nested process group before clone release; a clone whose positive ownership cannot be established remains inspectable.

The example deliberately resolves released Keiro packages with Cabal inside `nix develop`; the Seihou-pinned Nix package set does not contain Keiro. This matrix records verified coverage, rather than implied support:

| Environment | Compiler | PostgreSQL | Service cohort | Evidence |
| --- | --- | --- | --- | --- |
| macOS 26.7, Apple Silicon | GHC 9.12.4 | 18.6 | Keiro/keiro-migrations 0.19.0.0; Keiki 0.9.1; Kiroku Store 0.9.0.1; kiroku-store-migrations 0.6; pg-migrate 1.2 | Disposable socket/TCP PostgreSQL suites, Keiro/workbench example, unpacked source distributions, local Nix checks, and [benchmark](performance.md) |
| Other OS/compiler/PostgreSQL versions | — | — | — | Untested; run the integration and release gates before claiming support |
