---
type: Tutorial
title: "Run your first fixture plan"
description: "Compile a fixture without PostgreSQL, then run a disposable database example."
docId: DOC-5
tags: ["getting-started", "fixtures"]
generated:
  by: process:codex
  at: 2026-10-02T16:49:46Z
---

# Run your first fixture plan

This tutorial starts from a Hinagata checkout with Nix available.
Run all commands from the repository root.
The first procedure does not connect to PostgreSQL.

## Compile a fixture

1. Enter the development shell.

   ```sh
   nix develop
   ```

2. Build the CLI.

   ```sh
   cabal build hinagata-cli
   ```

3. Create a temporary workspace.

   ```sh
   fixture_demo=$(mktemp -d)
   mkdir -p "$fixture_demo/fixtures/first-fixture" "$fixture_demo/bundles"
   ```

4. Write the fixture file.

   ```sh
   cat > "$fixture_demo/fixtures/first-fixture/fixture.sql" <<'SQL'
   SELECT 1;
   SQL
   ```

5. Write the configuration file.

   ```sh
   cat > "$fixture_demo/hinagata.yaml" <<YAML
   endpoint:
     host: /nonexistent/hinagata-socket
     port: 5432
   project:
     id: first-fixture-demo
   fixture:
     root: $fixture_demo/fixtures
   bundle:
     root: $fixture_demo/bundles
   maintenance:
     database: postgres
   administration:
     user: demo_admin
     database: postgres
   setup:
     user: demo_setup
     database: postgres
   application:
     user: demo_app
     database: postgres
   YAML
   ```

   These connection values are placeholders for offline use.
   No server or roles are necessary for this procedure.

6. Validate the configuration.

   ```sh
   cabal run hinagata -- --config "$fixture_demo/hinagata.yaml" --check-config
   ```

   The result is `configuration valid`.

7. Compile the fixture.

   ```sh
   cabal run hinagata -- --config "$fixture_demo/hinagata.yaml" fixture plan first-fixture --json
   ```

   The report has `ok: true` and names `first-fixture`.
   The plan contains one SQL step.
   This result confirms capture and planning, not successful SQL execution.

8. Remove the temporary workspace when you finish.

   ```sh
   rm -r -- "$fixture_demo"
   unset fixture_demo
   ```

## Run a database example

1. Run the workbench example.

   ```sh
   just example-workbench
   ```

   The script starts a disposable socket-only PostgreSQL cluster.
   It runs HTTP suites with separate leases.
   It also tests failure retention and cancellation cleanup.
   The script stops the cluster when it finishes.

2. Read [Write and validate fixtures](../guides/write-fixtures.md) to create useful test data.

For service-owned migrations and separate roles, follow [Integrate a service](../guides/integrate-service.md).
