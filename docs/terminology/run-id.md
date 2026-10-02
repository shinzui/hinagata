---
type: Term
title: "run ID"
description: "An identifier that groups lease work and diagnostics for a run."
termId: TERM-24
status: current
tags: [operations]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-11, TERM-14]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Lease.hs
---

# run ID

An identifier that groups lease work and diagnostics for a run.

The CLI supplies this value as `HINAGATA_RUN_ID` to a child command.
For example, a service wrapper can include it in test reports.
The run ID is separate from the lease ID and allocation ID.
It does not select a database for deletion.
See [Command reference](../user/cli.md).
