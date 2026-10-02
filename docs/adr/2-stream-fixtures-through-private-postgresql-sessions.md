# ADR 2: Stream fixtures through private PostgreSQL sessions

Status: Accepted

Date: 2026-09-26

## Context

Small scenarios and large bulk datasets both matter. Per-row INSERTs, subprocesses per fixture, and full-dataset decoding add avoidable costs. The consumer fleet and upstream Hasql use different API generations.

## Decision

Compile deterministic graphs into immutable local bundles. Execute SQL and explicit CSV COPY in order within one transaction on one exclusive native connection. Use `postgresql-libpq` behind a private adapter with Hinagata-owned public endpoint types. Bound buffers and SQL step size, request single-row results for SQL commands, drain every result including the final COPY and COMMIT results, discard uncertain connections, and prevent handles escaping their resource lifetime. Keep all protocol operations under one session gate. Cancellation requests are best-effort and bounded; closing an interrupted connection forces PostgreSQL to roll back the uncommitted transaction. A failed ROLLBACK or ambiguous COMMIT retires the session.

## Consequences

Bulk data has bounded client memory. The adapter owns lifetime, cancellation, and backpressure proofs. Bounds require a released build-cohort check. SQL remains trusted transaction-compatible project code; sequence changes and external effects are not covered by rollback. Binary COPY and a public query DSL are deferred. See [research](../research/initial-design.md) for release and source evidence.
