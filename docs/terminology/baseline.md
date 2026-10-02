---
type: Term
title: "baseline"
description: "A reusable database state that Hinagata prepares for test clones."
termId: TERM-7
status: current
tags: [lifecycle]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-2, TERM-8, TERM-9, TERM-10]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Baseline.hs
---

# baseline

A reusable database state that Hinagata prepares for test clones.

Hinagata runs migrations, loads base fixtures, and verifies the result before sealing the database.
For example, many member tests can share one prepared schema and country list.
Tests connect to clones, not to the sealed baseline database.
See [How Hinagata works](../user/overview.md).
