---
type: Term
title: "fixture bundle"
description: "A private local copy of fixture files with recorded content digests."
termId: TERM-6
status: current
tags: [fixtures]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-5, TERM-25]
anchors:
  - kind: file
    resource: hinagata-core/src/Hinagata/Fixture/Bundle.hs
---

# fixture bundle

A private local copy of fixture files with recorded content digests.

Hinagata stores fixture bundles below `bundle.root`.
It verifies the captured bytes before reuse.
For example, a captured CSV file remains unchanged when its source file changes.
A fixture bundle holds test inputs; an OKF bundle holds documentation.
See [Fixture reference](../user/fixtures.md).
