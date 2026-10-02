---
type: Term
title: "acquisition deadline"
description: "The time limit for obtaining a prepared clone before control passes to the consumer."
termId: TERM-26
status: current
tags: [operations]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-11, TERM-22]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Manager.hs
---

# acquisition deadline

The time limit for obtaining a prepared clone before control passes to the consumer.

Managed acquisition includes queue wait within this limit.
The deadline ends at callback handoff.
For example, a long test can continue after acquisition has completed successfully.
This deadline does not bound the test's duration.
See [Configuration reference](../user/configuration.md).
