---
type: Term
title: "endpoint"
description: "The PostgreSQL server location specified by a socket directory or TCP hostname and a port."
termId: TERM-21
status: current
tags: [access]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-20]
anchors:
  - kind: file
    resource: hinagata-core/src/Hinagata/Connection.hs
---

# endpoint

The PostgreSQL server location specified by a socket directory or TCP hostname and a port.

An endpoint selects a server, not a database or role.
For example, a local endpoint can use an absolute Unix socket directory.
The port remains explicit for socket connections.
Hinagata connects to a server that the caller supplies.
See [Configuration reference](../user/configuration.md).
