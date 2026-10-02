---
type: Term
title: "connection target"
description: "An explicit endpoint, role, database, and optional password for a PostgreSQL connection."
termId: TERM-20
status: current
tags: [access]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-19, TERM-21]
anchors:
  - kind: file
    resource: hinagata-core/src/Hinagata/Connection.hs
---

# connection target

An explicit endpoint, role, database, and optional password for a PostgreSQL connection.

A target selects both the server and the access identity.
For example, two targets can use the same socket but different roles and databases.
The target's displayed form hides its password.
Hinagata exposes its own target type to consumers.
See [Configuration reference](../user/configuration.md).
