---
type: Term
title: "hook revision"
description: "A manual or explicitly content-derived identity for the effects of a migration or verification hook."
termId: TERM-23
status: current
tags: [lifecycle]
generated:
  by: process:codex
  at: 2026-10-18T19:46:53Z
related: [TERM-8, TERM-18]
anchors:
  - kind: file
    resource: hinagata-cli/src/Hinagata/Cli/Config.hs
---

# hook revision

A manual or explicitly content-derived identity for the effects of a migration or verification hook.

A revision tells Hinagata when those effects change.
For example, a service can use a migration content digest as its migration revision.
`Hinagata.Hook.Revision` derives versioned identities from named file bytes and non-secret literal values.
The CLI selects executable bytes only when requested and includes no physical paths or timestamps in the digest.
Undeclared inputs, remote state, and secret-controlled effects remain caller-owned and may require a manual revision.
Keep declared inputs stable while preparing; boundary checks do not create an atomic filesystem snapshot.
A command path alone does not prove stable effects.
Persistent baseline reuse needs both migration and verification revisions.
See [Configuration reference](../user/configuration.md).
