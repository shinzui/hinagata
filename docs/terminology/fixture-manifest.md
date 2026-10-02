---
type: Term
title: "fixture manifest"
description: "A YAML file that declares a fixture name, included fixtures, and ordered steps."
termId: TERM-4
status: current
tags: [fixtures]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-1, TERM-5]
anchors:
  - kind: file
    resource: hinagata-core/src/Hinagata/Fixture/Manifest.hs
---

# fixture manifest

A YAML file that declares a fixture name, included fixtures, and ordered steps.

The file is named `fixture.yaml` inside the fixture directory.
For example, a manifest can place a CSV step between two SQL steps.
Without a manifest, Hinagata uses one file named `fixture.sql`.
The manifest name must equal the directory name.
See [Fixture reference](../user/fixtures.md).
