---
type: Term
title: "application role"
description: "The PostgreSQL role that the service uses to access its test clone."
termId: TERM-19
status: current
tags: [access]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-17, TERM-18, TERM-20]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Lease.hs
---

# application role

The PostgreSQL role that the service uses to access its test clone.

`db with` supplies the application connection to its child command.
For example, the service uses this role to read fixture rows through its normal query code.
Service migrations supply required table and sequence grants.
The role does not automatically receive setup permissions.
See [Configuration reference](../user/configuration.md).
