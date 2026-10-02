---
type: Term
title: "fixture"
description: "A named description of database state that a test requires."
termId: TERM-1
status: current
tags: [fixtures]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-2, TERM-3, TERM-5]
anchors:
  - kind: file
    resource: hinagata-core/src/Hinagata/Fixture/Manifest.hs
---

# fixture

A named description of database state that a test requires.

A fixture contains SQL steps, CSV steps, or both.
For example, a member fixture can supply two accounts for a read test.
Each fixture has a directory below the configured fixture root.
A fixture can include other fixtures.
See [Fixture reference](../user/fixtures.md).
