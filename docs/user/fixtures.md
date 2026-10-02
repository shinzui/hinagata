---
type: Reference
title: "Fixture reference"
description: "Define SQL and CSV fixtures with explicit dependencies and ordered steps."
docId: DOC-4
tags: ["fixtures"]
generated:
  by: process:codex
  at: 2026-10-02T16:49:46Z
---

# Fixture reference

A [fixture](../terminology/fixture.md) is a named description of database state for a test.
Each fixture has one directory below `fixture.root`.
A directory without `fixture.yaml` uses one SQL file named `fixture.sql`.

## Manifest

```yaml
name: subscribed-members
description: Members with subscriptions
include:
  - reference-data
steps:
  - sql: prepare.sql
  - copy:
      table: { schema: app, name: members }
      columns: [id, email]
      file: members.csv
      format: csv
      header: true
  - sql: subscriptions.sql
```

The manifest name must equal the directory name.
`description` and `include` are optional.
`steps` must contain at least one entry.
Each step contains exactly one `sql` or `copy` field.
Unknown fields cause an error.

COPY requires a schema, table, nonempty column list, file, format, and header setting.
The format must be `csv`.
Hinagata quotes SQL identifiers and sends CSV bytes through `COPY FROM STDIN`.
The `header` setting tells PostgreSQL whether the CSV has a header row.

Step paths are relative to the fixture directory.
They must not be absolute or contain empty, `.` or `..` components.
Resolved files must stay inside the fixture root.

## Order and identity

Hinagata resolves included fixtures before their dependents.
Each fixture runs once in a plan.
Offline compilation rejects missing fixtures and dependency cycles.
The `fixture validate` command can prepare a baseline before it compiles individual scenarios.

Compilation captures the source bytes in a private fixture bundle.
File digests identify the captured contents.
Later source edits do not change an existing plan.
Hinagata verifies captured bytes before reuse.

A scenario can include a baseline fixture with the same name and identity.
Hinagata loads only the scenario remainder into the clone.
Conflicting contents or declarations cause an error.

## Transaction boundary

Hinagata loads one plan in one transaction on one connection.
SQL and CSV steps share that transaction.
An ordinary step failure rolls back the load.
Hinagata bounds CSV memory use with streaming buffers.

Fixture SQL is trusted project code.
Preflight rejects transaction-control statements, SQL `COPY`, and psql commands.
Use a manifest COPY step for CSV data.
PostgreSQL checks full SQL syntax and meaning.

Sequence advancement, stored functions, extensions, and external effects can escape rollback.
Avoid these effects when your procedure requires complete rollback.
See [Write and validate fixtures](../guides/write-fixtures.md) for a working example.
