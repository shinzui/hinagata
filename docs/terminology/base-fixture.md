---
type: Term
title: "base fixture"
description: "A fixture whose data belongs in a reusable baseline."
termId: TERM-2
status: current
tags: [fixtures]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
broader: [TERM-1]
related: [TERM-7, TERM-9]
anchors:
  - kind: file
    resource: hinagata-cli/src/Hinagata/Cli/Config.hs
---

# base fixture

A fixture whose data belongs in a reusable baseline.

Base fixtures contain data that multiple tests need.
For example, a base fixture can supply a fixed list of countries.
The CLI selects these fixtures through `baseline.fixtures`.
A scenario can include the same fixture without loading it twice into a clone.
See [Write and validate fixtures](../guides/write-fixtures.md).
