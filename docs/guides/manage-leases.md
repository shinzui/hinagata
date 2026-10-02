---
type: Runbook
title: "Inspect and release databases"
description: "Preserve failed test data and release selected leases or orphaned allocations."
docId: DOC-3
tags: ["cleanup", "lifecycle"]
generated:
  by: process:codex
  at: 2026-10-02T16:49:46Z
---

# Inspect and release databases

Use the same project configuration that created the lease.
Replace `CONFIG`, `NAME`, `PROGRAM`, and ID placeholders with your values.
A lease ID and an allocation ID identify different records.

## Preserve a failed test

1. Run the test with failure retention.

   ```sh
   cabal run hinagata -- --config CONFIG db with --fixture NAME --preserve-on-failure --json -- PROGRAM ARGS...
   ```

2. Record the lease ID from the report.
3. Inspect the lease.

   ```sh
   cabal run hinagata -- --config CONFIG inspect LEASE_ID --json
   ```

4. Use the reported database and your configured application credentials to investigate the failure.
5. Stop all processes that use the clone before release.
6. Release the lease when the investigation is complete.

   ```sh
   cabal run hinagata -- --config CONFIG db release LEASE_ID --json
   ```

   A repeated release of an already released lease is safe.
   An unknown lease ID causes refusal.
   `db acquire` also leaves a lease that needs explicit release.

## Recover an orphaned allocation

1. Read the cleanup preview.

   ```sh
   cabal run hinagata -- --config CONFIG clean --json
   ```

2. Find the allocation for your failed operation.
3. Confirm that its owner process has stopped.
4. Apply cleanup to its allocation ID.

   ```sh
   cabal run hinagata -- --config CONFIG clean --apply --id ALLOCATION_ID --json
   ```

5. For a retained allocation, add `--include-retained` only when you intend to remove it.

   ```sh
   cabal run hinagata -- --config CONFIG clean --apply --include-retained --id ALLOCATION_ID --json
   ```

   Cleanup checks ownership again at apply time.
   The preview does not grant permission for later deletion.

## Interpret the classification

| Classification | Meaning and action |
| --- | --- |
| `Live` | A process holds the lease lock. Stop that process before cleanup. |
| `Orphaned` | The allocation has no live holder. Review it before explicit cleanup. |
| `Retained` | The database remains for later use or investigation. Use explicit release when finished. |
| `Ambiguous` | Ownership evidence is incomplete or inconsistent. Investigate the catalog and database identity. |
| `Foreign` | Ownership evidence does not match. Do not remove it through Hinagata cleanup. |
| `Missing` | The recorded database is absent. Explicit cleanup can reconcile an eligible record. |

Do not infer ownership from a database name.
Do not edit ownership records to force cleanup.
If ownership remains uncertain, keep the evidence for investigation.

Cancellation stops the child process group before clone release.
If Hinagata cannot confirm that the group stopped, it preserves the clone.
A failed test and failed cleanup can appear together in the report.
See [Command reference](../user/cli.md) for exit codes.
