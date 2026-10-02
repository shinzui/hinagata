---
type: Term
title: "clone"
description: "An isolated database copied from a sealed baseline for a test."
termId: TERM-10
status: current
tags: [lifecycle]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-3, TERM-7, TERM-11]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Lease.hs
---

# clone

An isolated database copied from a sealed baseline for a test.

Hinagata loads scenario fixtures before it gives the clone to the consumer.
For example, two test processes can change separate member rows in separate clones.
Their database changes do not affect each other.
The lease determines when Hinagata releases or preserves the clone.
See [Integrate a service](../guides/integrate-service.md).
