---
type: Term
title: "scenario fixture"
description: "A fixture that supplies the additional state for a particular test scenario."
termId: TERM-3
status: current
tags: [fixtures]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
broader: [TERM-1]
related: [TERM-2, TERM-10]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Internal/Load.hs
---

# scenario fixture

A fixture that supplies the additional state for a particular test scenario.

A scenario fixture changes the clone after baseline preparation.
For example, it can add a member with an expired subscription.
Hinagata loads only the scenario remainder when the plan shares unchanged base fixtures.
See [Integrate a service](../guides/integrate-service.md).
