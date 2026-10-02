---
type: Term
title: "hook revision"
description: "A caller-supplied identity for the effects of a migration or verification hook."
termId: TERM-23
status: current
tags: [lifecycle]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-8, TERM-18]
anchors:
  - kind: file
    resource: hinagata-cli/src/Hinagata/Cli/Config.hs
---

# hook revision

A caller-supplied identity for the effects of a migration or verification hook.

A revision tells Hinagata when those effects change.
For example, a service can use a migration content digest as its migration revision.
A command path alone does not prove stable effects.
Persistent baseline reuse needs both migration and verification revisions.
See [Configuration reference](../user/configuration.md).
