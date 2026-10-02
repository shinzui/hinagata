---
type: Term
title: "retained lease"
description: "A lease whose clone remains available after normal execution for later use or investigation."
termId: TERM-13
status: current
tags: [lifecycle]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
broader: [TERM-11]
related: [TERM-12, TERM-14]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Cleanup.hs
---

# retained lease

A lease whose clone remains available after normal execution for later use or investigation.

For example, `db with --preserve-on-failure` can keep the database after a failed test.
The cleanup preview classifies retained allocations separately from ordinary orphaned work.
Explicit lease release can remove the retained clone.
Cleanup by allocation ID also requires `--include-retained`.
See [Inspect and release databases](../guides/manage-leases.md).
