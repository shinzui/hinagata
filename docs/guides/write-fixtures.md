---
type: Guide
title: "Write and validate fixtures"
description: "Create a schema fixture and CSV scenario, then validate the result."
docId: DOC-5
tags: ["fixtures"]
generated:
  by: process:codex
  at: 2026-10-02T16:49:46Z
---

# Write and validate fixtures

This procedure assumes a configured test server with separate administration, setup, and application roles.
`CONFIG` is your configuration file.
`FIXTURE_ROOT` is its absolute `fixture.root` value.
Replace these placeholders before execution.

## Create the schema fixture

1. Create `FIXTURE_ROOT/member-schema`.
2. Write `member-schema/fixture.sql` with this content.

   ```sql
   CREATE TABLE public.members (
     id bigint PRIMARY KEY,
     email text NOT NULL UNIQUE
   );
   ```

3. Add `member-schema` to `baseline.fixtures` in `CONFIG`.

   ```yaml
   baseline:
     fixtures: [member-schema]
   ```

   This example creates its table through a fixture.
   For a service-owned schema, use the service migration hook instead.

## Create the scenario fixture

1. Create `FIXTURE_ROOT/seeded-members`.
2. Write `seeded-members/members.csv` with this content.

   ```csv
   id,email
   1,member@example.test
   2,other@example.test
   ```

3. Write `seeded-members/fixture.yaml` with this content.

   ```yaml
   name: seeded-members
   description: Two members for read tests
   include: [member-schema]
   steps:
     - copy:
         table: { schema: public, name: members }
         columns: [id, email]
         file: members.csv
         format: csv
         header: true
   ```

## Validate the scenario

1. Compile the scenario without a database connection.

   ```sh
   cabal run hinagata -- --config CONFIG fixture plan seeded-members --json
   ```

   The plan puts `member-schema` before `seeded-members`.
   A missing include or invalid manifest causes an error here.

2. Validate the scenario against PostgreSQL.

   ```sh
   cabal run hinagata -- --config CONFIG fixture validate seeded-members --json
   ```

   Hinagata prepares the baseline and tests the scenario in a separate clone.
   It does not create the shared schema twice in that clone.
   SQL or CSV errors cause validation failure.

3. Grant the application role table access in your schema setup before service tests.

For direct loading, select an existing database with `--target-database`.
The complete plan above creates a table, so that table must not already exist in the direct-load target.
A repeated direct load is not a database reset.

Use stable fixture values when tests require repeatable data.
Avoid external effects when rollback must undo the full setup.
See [Fixture reference](../user/fixtures.md) for limits and manifest fields.
