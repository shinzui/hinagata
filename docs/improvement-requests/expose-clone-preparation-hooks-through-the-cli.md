---
type: Improvement Request
title: "Expose clone preparation hooks through the CLI"
description: "Expose the existing library clone-preparation hook in CLI configuration so each disposable clone can be seeded through service-owned command APIs before scenario fixtures and consumer startup."
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-10-18T18:30:53Z"
requestId: IR-1
status: accepted
targetPlan: docs/plans/6-expose-clone-preparation-hooks-through-the-cli.md
origin: mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract
acceptanceCriteria:
  - id: AC-1
    statement: "CLI configuration accepts a clone-preparation executable, argv, working directory, declared environment, and deadline, while absence preserves current behavior."
    verification: "Configuration/parser tests and original-config regressions exercise the new optional hook."
  - id: AC-2
    statement: "The hook runs once on every fresh clone with setup access, before scenario loading and application handoff; it never runs against the sealed baseline."
    verification: "Two leases use a command-backed seed helper and verify distinct clone state, invocation ordering, and an unchanged baseline."
  - id: AC-3
    statement: "Adding or changing clone preparation does not rebuild an unchanged baseline, and every subsequent lease uses the selected hook."
    verification: "Prepare, reuse, change the hook, and acquire again; assert the preparation remains Reused and the new clone receives the new seed."
  - id: AC-4
    statement: "Hook failure, timeout, or cancellation prevents consumer startup and follows the existing ownership-checked cleanup or preservation behavior, with phase-specific diagnostics."
    verification: "Inject each failure and verify zero application starts, bounded process cleanup, and inspectable ownership records when release cannot safely complete."
  - id: AC-5
    statement: "An integration example seeds event-backed state through public service command/store APIs and observes it through HTTP after service startup."
    verification: "Extend the Keiro/workbench example to exercise a command-backed clone seed; assert no fixture SQL fabricates event, outbox, or workflow rows."
reviews:
  - kind: model
    reviewer: codex-cli
    reviewed_at: "2026-10-11T16:18:19Z"
    document_timestamp: "2026-10-11T16:18:19Z"
    scope: technical-accuracy
    outcome: commented
    provider: openai
    model: gpt-6.1-sol
    effort: high
    context: >-
      Author's source assessment for Rei MP29 adoption, not an independent approval
      or implementation test result. Current interfaces and limitations were checked
      against the repository source and integration documentation; acceptance tests
      below are proposed verification procedures.
---

# Expose clone preparation hooks through the CLI

## Context

`Hinagata.Postgres.Baseline.BaselineSpec` already has `clonePreparationHook`, and library tests cover execution before handoff and release after hook failure. At commit `12875c862dba53439dbf51562d032d56fe9f31b9`, `Hinagata.Cli.Command.prepareBaseline` always sets `clonePreparationHook = Nothing`. The CLI exposes migration and verification hooks, but not this per-clone seam.

mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract creates command targets through real domain commands. SQL and CSV are suitable for independent read fixtures, but fabricated runtime rows cannot replace those targets or prove public command visibility.

## Request

Expose the existing library hook through optional CLI settings and reuse the executable-plus-argv runner, setup connection handoff, deadline, and cleanup behavior. The hook runs after clone creation, before scenario suffix loading, and before application access is handed to the consumer. Document ordering explicitly so authors can choose a baseline seed, per-clone command seed, and scenario fixture correctly.

This hook executes for every clone and is not baseline construction. Changing it must not invalidate an otherwise identical sealed template. Correlate diagnostics with the lease/run when available, keeping credentials private.

## Scope and adoption

Useful before adopting Hinagata through its CLI for command-backed fixture families. Direct Haskell consumers can already use the library hook. Keep migrations and domain seeding service-owned; PostgreSQL startup and projection-worker supervision remain caller responsibilities.


## Implementation plan

Accepted for implementation in [ExecPlan 6: Expose clone preparation hooks through the CLI](../plans/6-expose-clone-preparation-hooks-through-the-cli.md). The plan covers AC-1 through AC-5; implementation and acceptance verification have not started.
