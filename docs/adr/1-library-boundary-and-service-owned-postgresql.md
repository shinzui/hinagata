# ADR 1: Library boundary and service-owned PostgreSQL

Status: Accepted

Date: 2026-09-26

## Context

The old spec predates `mori://shinzui/hurl-workbench`. Services already bootstrap PostgreSQL, commonly on a Unix socket. The user wants a Haskell library and Settei settings.

## Decision

Hinagata supplies pure fixture planning, native PostgreSQL loading, and owned database leases with a thin CLI. The caller owns PostgreSQL and service startup. Direct loading grants no deletion authority. Hurl-workbench owns HTTP execution, readiness, and reporting. A generic bracketed command encloses the external test lifecycle within a database lease.

Configuration uses Settei; library callers can pass resolved values. Public types are independent of the consumer's driver/effect system. Keiro integration uses application migration/verification hooks and public runtime APIs, respecting `mori://shinzui/keiro/okf/adrs/concepts/ADR-9` and `mori://shinzui/keiro/okf/adrs/concepts/ADR-28`.

Development tooling is bootstrapped by `mori://shinzui/seihou-modules/templates/nix-haskell-flake`, with its managed lock/modules preserved and project customizations in `flake.module.nix`. This is a development dependency; production library calls do not bootstrap PostgreSQL.

Administration, setup, and application endpoints have explicit roles. Application handoff never implicitly uses administrative credentials. Suite-scoped resource limits and result classification belong to the library; adapters may map test-framework outcomes without introducing a framework dependency. Service bootstrap retains global-role ownership.

## Consequences

Existing PostgreSQL is reused without startup cost. Services receive clone settings before startup. No Hurl parser, invented workbench hook, or private runtime-table mutation is introduced. Portable dump snapshots, provisioning, and general orchestration are deferred. Cluster-local baseline snapshots are included under [ADR 3](3-sealed-baselines-and-positive-database-ownership.md).
