---
type: Term
title: "clone strategy"
description: "The PostgreSQL copy method selected for database clone creation."
termId: TERM-28
status: current
tags: [lifecycle]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-7, TERM-10]
anchors:
  - kind: file
    resource: hinagata-core/src/Hinagata/Config.hs
---

# clone strategy

The PostgreSQL copy method selected for database clone creation.

The `clone.strategy` setting defaults to `WAL_LOG`.
`FILE_COPY` is an explicit alternative.
For example, a team can compare their measured clone times before changing the setting.
One method does not guarantee better performance on every server.
See [Performance evidence](../performance.md).
