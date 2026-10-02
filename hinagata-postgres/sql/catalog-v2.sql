-- Transactional schema bootstrap. The caller substitutes one quoted,
-- validated SQL identifier for %SCHEMA% before dispatch.
CREATE SCHEMA %SCHEMA%;

CREATE TABLE %SCHEMA%.meta (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  format_version integer NOT NULL CHECK (format_version = 2),
  cluster_uuid uuid NOT NULL
);

INSERT INTO %SCHEMA%.meta (singleton, format_version, cluster_uuid)
VALUES (true, 2, gen_random_uuid());

CREATE TABLE %SCHEMA%.generations (
  id text PRIMARY KEY,
  project_id text NOT NULL,
  fingerprint text NOT NULL,
  fingerprint_manifest jsonb NOT NULL,
  database_name name NOT NULL UNIQUE,
  database_oid oid,
  ownership_token uuid NOT NULL,
  state text NOT NULL CHECK (state IN ('Building', 'Ready', 'Failed', 'Retiring')),
  last_error text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX generations_lookup ON %SCHEMA%.generations (project_id, fingerprint, state);

CREATE TABLE %SCHEMA%.allocations (
  id text PRIMARY KEY,
  project_id text NOT NULL,
  generation_id text NOT NULL REFERENCES %SCHEMA%.generations(id),
  run_id text,
  database_name name NOT NULL UNIQUE,
  database_oid oid,
  ownership_token uuid NOT NULL,
  state text NOT NULL CHECK (state IN ('Allocating', 'Loading', 'Active', 'Detached', 'Preserved', 'Releasing', 'Released', 'CleanupFailed')),
  last_error text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE %SCHEMA%.leases (
  id text PRIMARY KEY,
  allocation_id text NOT NULL UNIQUE REFERENCES %SCHEMA%.allocations(id),
  run_id text NOT NULL,
  state text NOT NULL CHECK (state IN ('Loading', 'Active', 'Detached', 'Preserved', 'Releasing', 'Released', 'CleanupFailed')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
