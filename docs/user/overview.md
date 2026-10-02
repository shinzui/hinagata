---
type: Explanation
title: "How Hinagata works"
description: "Understand fixture loading, baseline reuse, and isolated database leases."
docId: DOC-6
tags: ["lifecycle", "fixtures"]
generated:
  by: process:codex
  at: 2026-10-02T16:49:46Z
---

# How Hinagata works

Hinagata prepares PostgreSQL data before a test starts.
Your test system starts PostgreSQL and supplies the endpoint.
Hinagata does not start a server, container, or daemon.

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

Each [clone](../terminology/clone.md) receives its scenario fixtures before the test starts.
Changes in one clone do not change another clone.
A [lease](../terminology/lease.md) controls use and cleanup of that clone.

```text
Caller starts PostgreSQL
  -> build or reuse sealed baseline
  -> create clone
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
