#!/usr/bin/env bash
set -euo pipefail

mode="${1:-test}"
run_case() {
  case "$mode" in
    test|--tcp) cabal test hinagata-postgres-test --test-show-details=direct ;;
    --bench)
      cabal bench hinagata-postgres-direct-load --benchmark-options='100000 +RTS -s'
      cabal bench hinagata-postgres-direct-load --benchmark-options='1000000 +RTS -s'
      ;;
    *) echo "unknown mode: $mode" >&2; exit 2 ;;
  esac
}

if [[ -n "${HINAGATA_TEST_PGHOST:-}" ]]; then
  if [[ "$mode" == --bench ]]; then
    echo "benchmark requires the disposable PostgreSQL cluster" >&2
    exit 2
  fi
  export HINAGATA_TEST_PGPORT="${HINAGATA_TEST_PGPORT:-5432}"
  export HINAGATA_TEST_PGUSER="${HINAGATA_TEST_PGUSER:-$(id -un)}"
  export HINAGATA_TEST_PGDATABASE="${HINAGATA_TEST_PGDATABASE:-hinagata_test}"
  run_case
  exit
fi

root=$(mktemp -d /tmp/hinagata-pg.XXXXXX)
socket="$root/socket dir"
mkdir -p "$socket"
port=$((20000 + ($$ % 30000)))

cleanup() {
  pg_ctl -D "$root/data" -m immediate -w stop >/dev/null 2>&1 || true
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

initdb -D "$root/data" --auth=trust --no-locale --encoding=UTF8 --no-instructions >/dev/null
listen_addresses=""
if [[ "$mode" == --tcp ]]; then
  listen_addresses=127.0.0.1
  export HINAGATA_TEST_TCP=1
fi
pg_ctl -D "$root/data" -l "$root/postgres.log" -o "-k '$socket' -p $port -c listen_addresses='$listen_addresses'" -w start >/dev/null
createdb -h "$socket" -p "$port" hinagata_test

export HINAGATA_TEST_PGHOST="$socket"
export HINAGATA_TEST_PGPORT="$port"
export HINAGATA_TEST_PGUSER="$(id -un)"
export HINAGATA_TEST_PGDATABASE=hinagata_test
run_case
