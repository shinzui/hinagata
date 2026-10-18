# Changelog

## 0.1.0.0 - 2026-10-18

### New Features

- Compile ordered SQL and CSV fixtures with dependency resolution, manifest validation, path containment, and deterministic plan identities.
- Capture verified fixture bundles with SHA-256 digests, bounded streaming, and SQL size and transaction-policy checks.
- Expose validated identifiers, explicit connection descriptions, structured errors, and typed configuration declarations with secret redaction.
- Derive baseline hook revisions from declared executable bytes, files, and non-secret values.

### Bug Fixes

- Reject transaction-control statements using all PostgreSQL whitespace characters.
- Prevent ambient host-address settings from overriding explicit connection targets.
- Close interrupted capture resources and remove incomplete bundles on cancellation.

### Other Changes

- Include package changelog and repository metadata, and bound the test suite's dependency on hinagata-core to the shared release series.
