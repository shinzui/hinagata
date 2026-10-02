---
type: Term
title: "setup role"
description: "The PostgreSQL role that performs migrations, verification, and fixture loading."
termId: TERM-18
status: current
tags: [access]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-17, TERM-19, TERM-23]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Internal/Access.hs
---

# setup role

The PostgreSQL role that performs migrations, verification, and fixture loading.

The setup role prepares database state before application use.
For example, it creates a table and loads reference rows.
Its permissions can exceed the application's permissions.
Hooks must close their setup connections before they return.
See [Integrate a service](../guides/integrate-service.md).
