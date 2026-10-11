---
type: Improvement Request
title: "Verify Linux fixture and workbench lifecycle in CI"
description: "Add reproducible Linux CI evidence for PostgreSQL fixtures, database leases, command hooks, cancellation, and the Hinagata/workbench service handoff before claiming Linux integration support."
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-10-11T16:18:19Z"
requestId: IR-3
status: proposed
origin: mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract
acceptanceCriteria:
  - id: AC-1
    statement: "A documented Linux CI job runs the relevant source-distribution, PostgreSQL socket/TCP, CLI lifecycle, and Keiro/workbench integration gates on a disposable server."
    verification: "A CI run records the source revision, compiler, PostgreSQL/client versions, architecture, and passing gate outputs."
  - id: AC-2
    statement: "The integration job proves independent concurrent leases, normal completion, command/read observation, failed readiness, hook failure, and interruption cleanup."
    verification: "Exercise all paths and assert no unpreserved owned databases or child processes remain after their scopes."
  - id: AC-3
    statement: "Failure artifacts retain non-secret phase diagnostics and lease/run correlation while fixture connections and credentials remain isolated."
    verification: "Inject an integration failure and inspect uploaded reports for useful phase context and absence of sentinel credentials."
  - id: AC-4
    statement: "The compatibility matrix distinguishes newly verified Linux combinations from environments that remain untested."
    verification: "Update docs/integration.md only with the actual tested cohort and link to reproducible commands and run evidence."
  - id: AC-5
    statement: "Correctness CI does not promote reference-machine performance numbers into Linux guarantees or require unstable latency thresholds."
    verification: "Review the job configuration and documentation; performance benchmarking stays a separately described evidence-producing command."
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

# Verify Linux fixture and workbench lifecycle in CI

## Context

At commit `12875c862dba53439dbf51562d032d56fe9f31b9`, `docs/integration.md` records verified macOS 26.7, Apple Silicon, GHC 9.12.4, and PostgreSQL 18.6 coverage. Other OS/compiler/PostgreSQL combinations are explicitly untested, and there is no `.github` workflow directory in that checkout.

mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract will use the fixture lifecycle in local and CI gates. Successful local integration does not establish Linux process-group, Unix-socket, archive-build, or cancellation behavior.

## Request

Add a Linux correctness job running the existing lifecycle and real-service gates against disposable PostgreSQL. Select and record a supported cohort using current upstream package/release evidence when implementation chooses pins. Keep cluster provisioning in the job or harness; Hinagata continues to connect to a caller-owned server.

Include failure and cancellation witnesses, independent concurrent data assertions, and safe retained diagnostics. Update the compatibility matrix only after actual passing evidence. Preserve the existing macOS evidence and distinguish correctness coverage from platform-specific benchmarks.

## Scope and adoption

Required before making a Linux CI support claim. It is independent of the clone-hook and revision-helper feature requests; extend the job with their cases when those features land. No unmeasured performance target or additional runtime service is introduced.

