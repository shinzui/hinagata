---
type: Term
title: "database ownership"
description: "Evidence that authorizes Hinagata to manage and remove a specific database it created."
termId: TERM-15
status: current
tags: [operations]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-14, TERM-16]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Ownership.hs
---

# database ownership

Evidence that authorizes Hinagata to manage and remove a specific database it created.

Ownership combines catalog records with database identity evidence.
A database name alone does not establish ownership.
For example, a replacement database with an old name must not inherit deletion permission.
Hinagata refuses cleanup when the evidence does not match.
See [Inspect and release databases](../guides/manage-leases.md).
