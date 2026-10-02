---
type: Term
title: "lease"
description: "A controlled period of exclusive clone use with a cleanup responsibility."
termId: TERM-11
status: current
tags: [lifecycle]
generated:
  by: process:codex
  at: 2026-10-02T16:52:40Z
related: [TERM-10, TERM-12, TERM-13, TERM-14, TERM-24]
anchors:
  - kind: file
    resource: hinagata-postgres/src/Hinagata/Postgres/Lease.hs
---

# lease

A controlled period of exclusive clone use with a cleanup responsibility.

A lease gives the consumer an application connection and a lease ID.
For example, `db with` holds a lease while its child command runs.
The consumer must close its connections before release.
A lease ID identifies use of a clone; an allocation ID identifies the database allocation record.
See [Inspect and release databases](../guides/manage-leases.md).
