---
type: Term
title: "baseline fingerprint"
description: "An identity computed from the inputs that determine a reusable baseline."
termId: TERM-8
status: current
tags: [lifecycle]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-7, TERM-9, TERM-23]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Baseline.hs
---

# baseline fingerprint

An identity computed from the inputs that determine a reusable baseline.

Inputs include fixture digests, hook revisions, server major version, and relevant access settings.
A changed input selects a new fingerprint.
For example, a changed migration revision requires a new baseline generation.
Missing migration or verification revisions prevent persistent reuse.
See [Configuration reference](../user/configuration.md).
