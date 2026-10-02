---
type: Term
title: "maintenance catalog"
description: "Persistent records of Hinagata database generations, allocations, leases, and ownership."
termId: TERM-16
status: current
tags: [operations]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-14, TERM-15, TERM-17]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Ownership.hs
---

# maintenance catalog

Persistent records of Hinagata database generations, allocations, leases, and ownership.

The catalog lives in the configured maintenance database and schema.
It permits lifecycle inspection across process exits.
For example, cleanup can find allocations left by an interrupted process.
An owned older catalog can require an upgrade before read-only inspection.
See [Configuration reference](../user/configuration.md).
