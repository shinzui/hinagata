---
type: Improvement Request
title: "Derive baseline hook revisions from declared content inputs"
description: "Provide deterministic content-derived migration and verification revisions from explicit executable, SQL, manifest, and configuration inputs so fixture authors can keep reusable baselines aligned with changing schema effects."
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-10-18T18:46:32Z"
requestId: IR-2
status: accepted
targetPlan: docs/plans/7-derive-baseline-hook-revisions-from-declared-content-inputs.md
origin: mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract
acceptanceCriteria:
  - id: AC-1
    statement: "A revision helper accepts explicitly declared inputs and produces a versioned deterministic digest with stable logical input names and ordering."
    verification: "Repeat with equivalent input sets under different temporary checkout roots; assert the same digest and no dependency on modification times."
  - id: AC-2
    statement: "Changes to any declared executable, migration SQL, manifest, verification code, or relevant non-secret configuration value change the derived revision; unchanged inputs permit baseline reuse."
    verification: "A disposable service example independently changes each declared input and verifies Built after a prior Reused call."
  - id: AC-3
    statement: "Missing or unreadable declared inputs fail preparation before baseline reuse or migration execution, and reports omit input contents and secret values."
    verification: "Negative filesystem cases and sentinel-sensitive-data checks assert no hook invocation and safe diagnostics."
  - id: AC-4
    statement: "The existing explicit revision mechanism and missing-revision behavior remain supported; ambiguous configuration combining explicit and derived modes is rejected."
    verification: "Regression cases preserve manual revisions and rebuild-without-revisions semantics, and reject conflicting modes."
  - id: AC-5
    statement: "Documentation defines the declared-input boundary, configuration effects, and changes that require a caller-supplied revision rather than an inferred digest."
    verification: "Review the example and reference against an external SQL input that changes without changing the migration executable."
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

# Derive baseline hook revisions from declared content inputs

## Context

Baseline fingerprints include migration and verification revisions. CLI configuration currently relies on callers supplying those revision strings; missing revisions correctly disable persistent reuse. The Keiro example hashes its built migration executable, which is appropriate for its embedded SQL but does not by itself identify arbitrary external files or configuration read by another hook.

mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract changes inline read-model DDL, indexes, and migration manifests across many milestones. A declared-input helper would reduce accidental reuse of a baseline whose schema inputs changed. This is an authoring convenience over the existing cache contract, not evidence that a current cache defect has been reproduced.

## Request

Add a deterministic helper or configuration mode deriving a hook revision from explicit content inputs. Include a version marker, normalized logical labels, executable bytes when selected, and caller-selected configuration that affects hook output. Capture or verify inputs consistently before deciding reuse; fail if a selected input cannot be read.

Keep manual revisions available for effects that cannot be represented by declared files. Never claim to discover every dependency of an arbitrary executable. Document that changing undeclared remote state, environment, or service behavior remains the caller's responsibility. Avoid absolute machine paths, timestamps, or secret values in user-facing digest explanations.

## Scope and adoption

Recommended before relying on persistent baseline reuse during rapid schema development. It does not require schema diffing, automatic data capture, or migration ownership inside Hinagata. Existing explicit revisions remain sufficient for a correctly configured first adopter.

## Implementation plan

Accepted for implementation in [ExecPlan 7: Derive baseline hook revisions from declared content inputs](../plans/7-derive-baseline-hook-revisions-from-declared-content-inputs.md). The plan covers AC-1 through AC-5; implementation and acceptance verification have not started.
