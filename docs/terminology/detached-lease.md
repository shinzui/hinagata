---
type: Term
title: "detached lease"
description: "A lease that remains available for a separate process until explicit release."
termId: TERM-12
status: current
tags: [lifecycle]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
broader: [TERM-11]
related: [TERM-13]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Lease.hs
---

# detached lease

A lease that remains available for a separate process until explicit release.

`db acquire` returns a detached lease.
For example, a test launcher can pass its connection details to another process.
The caller must arrange release after that process stops.
Detached use does not remove Hinagata's ownership checks.
See [Command reference](../user/cli.md).
