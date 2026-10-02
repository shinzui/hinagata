---
type: Term
title: "direct loading"
description: "Fixture execution in an existing database that the caller owns and explicitly selects."
termId: TERM-27
status: current
tags: [fixtures]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-1, TERM-5, TERM-15]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Load.hs
---

# direct loading

Fixture execution in an existing database that the caller owns and explicitly selects.

The CLI selects this database through `--target-database`.
For example, an existing test harness can migrate a database before Hinagata loads its rows.
Hinagata does not gain permission to delete that database.
A repeated load can conflict with existing data.
See [Command reference](../user/cli.md).
