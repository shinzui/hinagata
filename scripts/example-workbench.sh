#!/usr/bin/env bash
set -euo pipefail

project="$(pwd)"
example="$project/examples/workbench"
binary="$(cabal list-bin hinagata)"
export hinagata_postgres_datadir="$project/hinagata-postgres"
workspace="$(mktemp -d)"
cleanup() {
  local status=$?
  if test "$status" -ne 0; then
    for log in "$workspace"/run-*.err; do
      test -f "$log" && cat "$log" >&2
    done
  fi
  rm -rf "$workspace"
}
trap cleanup EXIT
mkdir -p "$workspace/bundles" "$workspace/pids"

export HINAGATA_ENDPOINT_HOST="$HINAGATA_TEST_PGHOST"
export HINAGATA_ENDPOINT_PORT="$HINAGATA_TEST_PGPORT"
export HINAGATA_FIXTURE_ROOT="$example/fixtures"
export HINAGATA_BUNDLE_ROOT="$workspace/bundles"
export HINAGATA_MAINTENANCE_DATABASE="$HINAGATA_TEST_PGDATABASE"
export HINAGATA_ADMINISTRATION_USER="$HINAGATA_TEST_PGUSER"
export HINAGATA_ADMINISTRATION_DATABASE="$HINAGATA_TEST_PGDATABASE"
export HINAGATA_SETUP_USER="$HINAGATA_TEST_PGUSER"
export HINAGATA_SETUP_DATABASE="$HINAGATA_TEST_PGDATABASE"
export HINAGATA_APPLICATION_USER="$HINAGATA_TEST_PGUSER"
export HINAGATA_APPLICATION_DATABASE="$HINAGATA_TEST_PGDATABASE"
export EXAMPLE_SERVICE_PID_DIR="$workspace/pids"

"$binary" --config "$example/hinagata.yaml" --check-config > "$workspace/check.txt"
"$binary" --config "$example/hinagata.yaml" fixture plan seeded-member --json > "$workspace/plan.json"

read -r first_port second_port < <(python3 - <<'PY'
import socket

with socket.socket() as first, socket.socket() as second:
    first.bind(("127.0.0.1", 0))
    second.bind(("127.0.0.1", 0))
    print(first.getsockname()[1], second.getsockname()[1])
PY
)
test "$first_port" != "$second_port"

workbench_ref='github:shinzui/hurl-workbench/a29d26ad5e90aa762de88be18f06fddf67b6d02f#default'
run_suite() {
  local label="$1" port="$2"
  "$binary" --config "$example/hinagata.yaml" db with --fixture seeded-member --json -- \
    nix shell "$workbench_ref" -c hurl-workbench \
      --workspace "$example/hurl-workbench.dhall" \
      test suite default \
      --variable "service_port=$port" \
      --variable "base_url=http://127.0.0.1:$port" \
      --report json --report-dir "$workspace/reports-$label" \
      > "$workspace/lease-$label.json" 2> "$workspace/run-$label.err"
  local lease_id
  lease_id="$(python3 - "$workspace/lease-$label.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["ok"] and result["status"] == 0
assert result["disposition"] == "LeaseReleased"
print(result["leaseId"])
PY
)"
  test -s "$workspace/pids/$lease_id"
  local service_pid
  service_pid="$(cat "$workspace/pids/$lease_id")"
  ! kill -0 "$service_pid" 2>/dev/null
  "$binary" --config "$example/hinagata.yaml" inspect "$lease_id" --json > "$workspace/inspect-$label.json"
  python3 - "$workspace/inspect-$label.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["candidate"]["state"] == "Released"
PY
  printf '%s\n' "$lease_id" > "$workspace/lease-id-$label"
}

run_suite first "$first_port"
run_suite second "$second_port"
first_lease="$(cat "$workspace/lease-id-first")"
second_lease="$(cat "$workspace/lease-id-second")"
test "$first_lease" != "$second_lease"

if "$binary" --config "$example/hinagata.yaml" db with --fixture seeded-member --preserve-on-failure --json -- \
  nix shell "$workbench_ref" -c hurl-workbench \
    --workspace "$example/hurl-workbench.dhall" \
    test suite intentional-failure \
    --variable "service_port=$first_port" \
    --variable "base_url=http://127.0.0.1:$first_port" \
    --report json --report-dir "$workspace/reports-failure" \
    > "$workspace/lease-failure.json" 2> "$workspace/run-failure.err"; then
  echo "intentional Hurl assertion unexpectedly passed" >&2
  exit 1
else
  child_status=$?
fi
failed_lease="$(python3 - "$workspace/lease-failure.json" "$child_status" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
status = int(sys.argv[2])
assert status > 0 and result["status"] == status
assert not result["ok"] and result["disposition"] == "LeasePreserved"
assert result["child"]["exitCode"] == status
print(result["leaseId"])
PY
)"
"$binary" --config "$example/hinagata.yaml" inspect "$failed_lease" --json > "$workspace/inspect-failure.json"
python3 - "$workspace/inspect-failure.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["candidate"]["disposition"] == "Retained"
PY
"$binary" --config "$example/hinagata.yaml" db release "$failed_lease" --json > "$workspace/release-failure.json"

export EXAMPLE_SERVICE_READY_FILE="$workspace/cancellation-service-pid"
"$binary" --config "$example/hinagata.yaml" db with --fixture seeded-member --json -- \
  nix shell "$workbench_ref" -c hurl-workbench \
    --workspace "$example/hurl-workbench.dhall" \
    test suite cancellation \
    --variable "service_port=$second_port" \
    --variable "base_url=http://127.0.0.1:$second_port" \
    --report json --report-dir "$workspace/reports-cancellation" \
    > "$workspace/lease-cancellation.json" 2> "$workspace/run-cancellation.err" &
wrapper_pid=$!
for attempt in $(seq 1 150); do
  if test -s "$EXAMPLE_SERVICE_READY_FILE" && curl --max-time 1 -sf "http://127.0.0.1:$second_port/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
test -s "$EXAMPLE_SERVICE_READY_FILE"
curl --max-time 2 -sf "http://127.0.0.1:$second_port/health" > "$workspace/cancellation-health.json"
service_pid="$(cat "$EXAMPLE_SERVICE_READY_FILE")"
kill -INT "$wrapper_pid"
if wait "$wrapper_pid"; then
  echo "cancelled workbench suite unexpectedly succeeded" >&2
  exit 1
else
  cancellation_status=$?
  test "$cancellation_status" -eq 130
fi
for attempt in $(seq 1 40); do
  if ! kill -0 "$service_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
! kill -0 "$service_pid" 2>/dev/null
cancelled_lease="$(python3 - "$workspace/lease-cancellation.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["status"] == 130 and result["child"]["outcome"] == "cancelled"
assert result["disposition"] == "LeaseReleased"
print(result["leaseId"])
PY
)"
"$binary" --config "$example/hinagata.yaml" inspect "$cancelled_lease" --json > "$workspace/inspect-cancellation.json"
python3 - "$workspace/inspect-cancellation.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["candidate"]["state"] == "Released"
PY

echo "hurl-workbench example passed two suites, preserved a failed assertion, and cleaned up cancellation"
