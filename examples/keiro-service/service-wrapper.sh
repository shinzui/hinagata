#!/usr/bin/env bash
set -euo pipefail

export SERVICE_PORT="${PORT:?workbench service_port is required}"
export SERVICE_PGHOST="${PGHOST:?PGHOST is required}"
export SERVICE_PGPORT="${PGPORT:?PGPORT is required}"
export SERVICE_PGUSER="${PGUSER:?PGUSER is required}"
export SERVICE_PGDATABASE="${PGDATABASE:?PGDATABASE is required}"

if [[ -n "${EXAMPLE_SERVICE_PID_DIR:-}" ]]; then
  printf '%s\n' "$$" > "$EXAMPLE_SERVICE_PID_DIR/$HINAGATA_LEASE_ID"
fi
if [[ -n "${EXAMPLE_SERVICE_READY_FILE:-}" ]]; then
  printf '%s\n' "$$" > "$EXAMPLE_SERVICE_READY_FILE"
fi
exec "${EXAMPLE_SERVICE_BINARY:?EXAMPLE_SERVICE_BINARY is required}"
