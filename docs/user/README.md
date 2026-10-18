---
type: Navigation
title: "Hinagata user documentation"
description: "Find instructions and reference information for PostgreSQL test databases."
docId: DOC-1
tags: ["navigation"]
generated:
  by: process:codex
  at: 2026-10-18T20:45:25Z
---

# Hinagata user documentation

Hinagata prepares PostgreSQL data for tests.
It can load fixtures into an existing database or give each test a separate database clone.
Your service or test system supplies the PostgreSQL server.
The libraries and CLI do not require Keiro.
The repository includes a test-only Keiro service to verify integration with a real application.

## Start here

1. Read [How Hinagata works](overview.md).
2. Follow [Run your first fixture plan](getting-started.md).
3. Select a procedure from the [task guides](../guides/README.md).

## Find information

| Need | Page |
| --- | --- |
| Commands, output, and exit codes | [Command reference](cli.md) |
| Connection settings and limits | [Configuration reference](configuration.md) |
| Fixture files and manifests | [Fixture reference](fixtures.md) |
| Project words | [Terminology by subject](terminology.md) |
| Measured performance | [Performance evidence](../performance.md) |
| Generic HTTP service example | [Workbench example](../../examples/workbench/README.md) |
| Keiro service integration example | [Keiro example](../../examples/keiro-service/README.md) |

The [specification](../initial-spec.md) gives the design contract.
The [project README](../../README.md) lists packages and development commands.
