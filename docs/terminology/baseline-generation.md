---
type: Term
title: "baseline generation"
description: "One recorded database instance that implements a baseline fingerprint."
termId: TERM-9
status: current
tags: [lifecycle]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-7, TERM-8, TERM-14]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Baseline.hs
---

# baseline generation

One recorded database instance that implements a baseline fingerprint.

A generation becomes reusable after successful preparation and sealing.
An incomplete build does not replace an earlier ready generation.
Several generations can remain recorded during development.
Explicit retirement of a sealed generation leaves its existing clones independent.
See [How Hinagata works](../user/overview.md).
