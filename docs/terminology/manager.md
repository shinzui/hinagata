---
type: Term
title: "manager"
description: "A local controller that bounds concurrent setup, active leases, and queued acquisition requests."
termId: TERM-22
status: current
tags: [operations]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-11, TERM-26]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Manager.hs
---

# manager

A local controller that bounds concurrent setup, active leases, and queued acquisition requests.

A test suite can share one manager across multiple clone requests.
For example, the manager can permit two setup workers and eight active leases.
These limits apply only to that manager.
Separate processes do not share a global admission limit.
See [Configuration reference](../user/configuration.md).
