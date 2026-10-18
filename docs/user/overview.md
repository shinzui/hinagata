---
type: Explanation
title: "How Hinagata works"
description: "Understand fixture loading, baseline reuse, and isolated database leases."
docId: DOC-6
tags: ["lifecycle", "fixtures"]
generated:
  by: process:codex
  at: 2026-10-18T20:45:25Z
---

# How Hinagata works

Hinagata prepares PostgreSQL data before a test starts.
Your test system starts PostgreSQL and supplies the endpoint.
Hinagata does not start a server, container, or daemon.
The libraries and CLI do not require Keiro or a particular service framework.
Your service supplies its migration and verification hooks.
The [Keiro service](../../examples/keiro-service/README.md) is a test-only integration example.

## Direct loading

Direct loading writes fixtures to an existing database that you select.
Your test system owns that database and its schema.
Hinagata does not acquire permission to drop, reset, or truncate it.
The complete fixture plan runs in one transaction.

Use direct loading when your test system already controls database isolation.
A repeated load can conflict with existing rows.
The [fixture reference](fixtures.md) explains the transaction limits.

## Baselines and clones

A [baseline](../terminology/baseline.md) is a reusable database state.
Hinagata builds a database, runs migrations, loads base fixtures, and verifies the result.
It then seals the database as a PostgreSQL template.
Tests use clones of that template.
They do not connect to the sealed template.

A [fingerprint](../terminology/baseline-fingerprint.md) identifies the baseline inputs.
These inputs include hook revisions, base fixtures, the server major version, and relevant role settings.
Unchanged inputs permit reuse of a valid sealed generation.
Changed inputs select a new generation.
Missing migration or verification revisions disable persistent reuse.
The CLI accepts manual revisions or derives them from declared executable bytes, files, and non-secret values.
Declare all relevant inputs; Hinagata does not discover arbitrary dependencies or remote state.
See [Content-derived baseline revisions](configuration.md#content-derived-baseline-revisions).

Each [clone](../terminology/clone.md) can run an optional preparation hook with setup access before receiving scenario fixtures.
The hook can create domain state through the service's command APIs before service startup.
It runs for each new clone, including clones of a reused baseline, and does not change baseline identity.
Failure, timeout, or cancellation prevents application handoff.
Uncertain process cleanup preserves the lease for inspection.
See [Per-clone preparation](configuration.md#per-clone-preparation).

The clone receives its scenario fixtures before the test starts.
Changes in one clone do not change another clone.
A [lease](../terminology/lease.md) controls use and cleanup of that clone.

```text
Caller starts PostgreSQL
  -> build or reuse sealed baseline
  -> create clone
  -> run optional clone preparation with setup access
  -> load scenario fixtures
  -> run service or test
  -> stop service and close connections
  -> release or preserve clone
```

## Access and ownership

The administration role manages databases and the maintenance catalog.
The setup role runs migrations, verification, and fixture loads.
The application role connects the service to its clone.
Service migrations grant table and sequence access to the application role.

Hinagata records database ownership in the maintenance catalog.
Cleanup compares the record with the database identity before deletion.
A matching database name alone is insufficient.
Uncertain ownership leaves the database available for investigation.

A manager bounds setup work, active leases, and queued requests within one process.
Separate managers do not share these limits.
See [Inspect and release databases](../guides/manage-leases.md) for failure recovery.
