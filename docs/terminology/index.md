---
okf_version: "0.2"
---

# Term

- [acquisition deadline](acquisition-deadline.md) - The time limit for obtaining a prepared clone before control passes to the consumer.
- [administration role](administration-role.md) - The PostgreSQL role that Hinagata uses for database lifecycle and catalog operations.
- [allocation](allocation.md) - A catalog record that tracks a clone Hinagata intends to create or has created.
- [application role](application-role.md) - The PostgreSQL role that the service uses to access its test clone.
- [base fixture](base-fixture.md) - A fixture whose data belongs in a reusable baseline.
- [baseline fingerprint](baseline-fingerprint.md) - An identity computed from the inputs that determine a reusable baseline.
- [baseline generation](baseline-generation.md) - One recorded database instance that implements a baseline fingerprint.
- [baseline](baseline.md) - A reusable database state that Hinagata prepares for test clones.
- [clone strategy](clone-strategy.md) - The PostgreSQL copy method selected for database clone creation.
- [clone](clone.md) - An isolated database copied from a sealed baseline for a test.
- [connection target](connection-target.md) - An explicit endpoint, role, database, and optional password for a PostgreSQL connection.
- [database ownership](database-ownership.md) - Evidence that authorizes Hinagata to manage and remove a specific database it created.
- [detached lease](detached-lease.md) - A lease that remains available for a separate process until explicit release.
- [direct loading](direct-loading.md) - Fixture execution in an existing database that the caller owns and explicitly selects.
- [endpoint](endpoint.md) - The PostgreSQL server location specified by a socket directory or TCP hostname and a port.
- [fixture bundle](fixture-bundle.md) - A private local copy of fixture files with recorded content digests.
- [fixture manifest](fixture-manifest.md) - A YAML file that declares a fixture name, included fixtures, and ordered steps.
- [fixture plan](fixture-plan.md) - An ordered set of captured fixture steps and identities that Hinagata can execute.
- [fixture](fixture.md) - A named description of database state that a test requires.
- [hook revision](hook-revision.md) - A caller-supplied identity for the effects of a migration or verification hook.
- [lease](lease.md) - A controlled period of exclusive clone use with a cleanup responsibility.
- [maintenance catalog](maintenance-catalog.md) - Persistent records of Hinagata database generations, allocations, leases, and ownership.
- [manager](manager.md) - A local controller that bounds concurrent setup, active leases, and queued acquisition requests.
- [OKF bundle](okf-bundle.md) - A directory of Markdown concepts governed by an Open Knowledge Format contract.
- [retained lease](retained-lease.md) - A lease whose clone remains available after normal execution for later use or investigation.
- [run ID](run-id.md) - An identifier that groups lease work and diagnostics for a run.
- [scenario fixture](scenario-fixture.md) - A fixture that supplies the additional state for a particular test scenario.
- [setup role](setup-role.md) - The PostgreSQL role that performs migrations, verification, and fixture loading.

