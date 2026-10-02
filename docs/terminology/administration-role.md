---
type: Term
title: "administration role"
description: "The PostgreSQL role that Hinagata uses for database lifecycle and catalog operations."
termId: TERM-17
status: current
tags: [access]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-16, TERM-18, TERM-19]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Internal/Access.hs
---

# administration role

The PostgreSQL role that Hinagata uses for database lifecycle and catalog operations.

This role needs permission to create and remove test databases.
It also accesses the maintenance catalog.
For example, it creates a clone before the service starts.
Hinagata does not pass administration credentials to the service.
See [Integrate a service](../guides/integrate-service.md).
