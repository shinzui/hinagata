---
type: Term
title: "fixture plan"
description: "An ordered set of captured fixture steps and identities that Hinagata can execute."
termId: TERM-5
status: current
tags: [fixtures]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-4, TERM-6]
anchors:
  - kind: file
    resource: hinagata-core/src/Hinagata/Fixture/Bundle.hs
---

# fixture plan

An ordered set of captured fixture steps and identities that Hinagata can execute.

Compilation resolves included fixtures and captures the source bytes.
It puts dependencies before the fixtures that need them.
Later edits to source files do not change this plan.
A valid plan does not prove that SQL execution will succeed.
See [Run your first fixture plan](../user/getting-started.md).
