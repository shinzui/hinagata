#!/usr/bin/env bash
set -euo pipefail

workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project="$(cd "$workspace/../.." && pwd)"
: "${PORT:?workbench service_port is required}"
: "${PGHOST:?lease PGHOST is required}"
: "${PGPORT:?lease PGPORT is required}"
: "${PGUSER:?lease PGUSER is required}"
: "${PGDATABASE:?lease PGDATABASE is required}"

export SERVICE_PORT="$PORT"
export SERVICE_PGHOST="$PGHOST"
export SERVICE_PGPORT="$PGPORT"
export SERVICE_PGUSER="$PGUSER"
export SERVICE_PGDATABASE="$PGDATABASE"

service="$(cabal --project-dir="$project" list-bin hinagata-workbench-service)"
if [[ -n "${EXAMPLE_SERVICE_PID_DIR:-}" ]]; then
  printf '%s\n' "$$" > "$EXAMPLE_SERVICE_PID_DIR/$HINAGATA_LEASE_ID"
fi
if [[ -n "${EXAMPLE_SERVICE_READY_FILE:-}" ]]; then
  printf '%s\n' "$$" > "$EXAMPLE_SERVICE_READY_FILE"
fi
exec "$service"
