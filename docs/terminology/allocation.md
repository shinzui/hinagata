---
type: Term
title: "allocation"
description: "A catalog record that tracks a clone Hinagata intends to create or has created."
termId: TERM-14
status: current
tags: [operations]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-9, TERM-11, TERM-15, TERM-16]
anchors:
  - kind: file
    resource: hinagata-postgres/sql/catalog-v2.sql
---

# allocation

A catalog record that tracks a clone Hinagata intends to create or has created.

An allocation exists across database creation and cleanup boundaries.
A failed operation can leave an allocation without a published lease.
For example, a process can stop after database creation but before lease publication.
`clean --id` selects an allocation ID.
See [Inspect and release databases](../guides/manage-leases.md).
