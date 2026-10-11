---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Derive baseline hook revisions from declared content inputs](derive-baseline-hook-revisions-from-declared-content-inputs.md) - Provide deterministic content-derived migration and verification revisions from explicit executable, SQL, manifest, and configuration inputs so fixture authors can keep reusable baselines aligned with changing schema effects.
- [Expose clone preparation hooks through the CLI](expose-clone-preparation-hooks-through-the-cli.md) - Expose the existing library clone-preparation hook in CLI configuration so each disposable clone can be seeded through service-owned command APIs before scenario fixtures and consumer startup.
- [Verify Linux fixture and workbench lifecycle in CI](verify-linux-fixture-and-workbench-lifecycle-in-ci.md) - Add reproducible Linux CI evidence for PostgreSQL fixtures, database leases, command hooks, cancellation, and the Hinagata/workbench service handoff before claiming Linux integration support.

