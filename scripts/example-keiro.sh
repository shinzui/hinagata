#!/usr/bin/env bash
set -euo pipefail

project="$(pwd)"
example="$project/examples/keiro-service"
export hinagata_postgres_datadir="$project/hinagata-postgres"
binary="$(cabal list-bin hinagata)"
migrate_binary="$(cabal list-bin hinagata-keiro-migrate)"
export EXAMPLE_SERVICE_BINARY="$(cabal list-bin hinagata-keiro-service)"
workspace="$(mktemp -d)"
cleanup() {
  local status=$?
  if test "$status" -ne 0; then
    for report in "$workspace"/lease-*.json; do
      test -f "$report" && cat "$report" >&2
    done
    for log in "$workspace"/run-*.err; do
      test -f "$log" && cat "$log" >&2
    done
  fi
  rm -rf "$workspace"
}
trap cleanup EXIT
mkdir -p "$workspace/bundles" "$workspace/pids"

psql -h "$HINAGATA_TEST_PGHOST" -p "$HINAGATA_TEST_PGPORT" -U "$HINAGATA_TEST_PGUSER" -d "$HINAGATA_TEST_PGDATABASE" -v ON_ERROR_STOP=1 -qAtc \
  'CREATE ROLE hinagata_example_setup LOGIN; CREATE ROLE hinagata_example_app LOGIN;'

export HINAGATA_ENDPOINT_HOST="$HINAGATA_TEST_PGHOST"
export HINAGATA_ENDPOINT_PORT="$HINAGATA_TEST_PGPORT"
export HINAGATA_FIXTURE_ROOT="$example/fixtures"
export HINAGATA_BUNDLE_ROOT="$workspace/bundles"
export HINAGATA_MAINTENANCE_DATABASE="$HINAGATA_TEST_PGDATABASE"
export HINAGATA_ADMINISTRATION_USER="$HINAGATA_TEST_PGUSER"
export HINAGATA_ADMINISTRATION_DATABASE="$HINAGATA_TEST_PGDATABASE"
export HINAGATA_SETUP_USER=hinagata_example_setup
export HINAGATA_SETUP_DATABASE="$HINAGATA_TEST_PGDATABASE"
export HINAGATA_APPLICATION_USER=hinagata_example_app
export HINAGATA_APPLICATION_DATABASE="$HINAGATA_TEST_PGDATABASE"
export HINAGATA_MIGRATION_EXECUTABLE="$migrate_binary"
export HINAGATA_VERIFICATION_EXECUTABLE="$migrate_binary"
revision="$(shasum -a 256 "$migrate_binary" | cut -d ' ' -f 1)"
export HINAGATA_MIGRATION_REVISION="$revision"
export HINAGATA_VERIFICATION_REVISION="$revision"
export EXAMPLE_SERVICE_PID_DIR="$workspace/pids"

"$binary" --config "$example/hinagata.yaml" --check-config > "$workspace/check.txt"
"$binary" --config "$example/hinagata.yaml" fixture plan service-scenario --json > "$workspace/plan.json"
"$binary" --config "$example/hinagata.yaml" db prepare --json > "$workspace/prepare-cold.json"
"$binary" --config "$example/hinagata.yaml" db prepare --json > "$workspace/prepare-warm.json"

export HINAGATA_MIGRATION_REVISION="$revision-change-probe"
"$binary" --config "$example/hinagata.yaml" db prepare --json > "$workspace/prepare-migration-changed.json"
export HINAGATA_MIGRATION_REVISION="$revision"

cp -R "$example/fixtures" "$workspace/changed-fixtures"
printf '\n-- changed base-fixture identity probe\n' >> "$workspace/changed-fixtures/reference-seed/fixture.sql"
export HINAGATA_FIXTURE_ROOT="$workspace/changed-fixtures"
"$binary" --config "$example/hinagata.yaml" db prepare --json > "$workspace/prepare-fixture-changed.json"
export HINAGATA_FIXTURE_ROOT="$example/fixtures"

python3 - "$workspace/prepare-cold.json" "$workspace/prepare-warm.json" "$workspace/prepare-migration-changed.json" "$workspace/prepare-fixture-changed.json" <<'PY'
import json
import pathlib
import sys

cold, warm, migration, fixture = (json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:])
assert cold["result"] == "Built" and warm["result"] == "Reused"
assert cold["fingerprint"] == warm["fingerprint"]
assert migration["result"] == "Built" and migration["fingerprint"] != cold["fingerprint"]
assert fixture["result"] == "Built" and fixture["fingerprint"] != cold["fingerprint"]
PY

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
  local label="$1" suite="$2" port="$3" mutating="$4" fixture="${5:-service-scenario}"
  local -a mutation_flag=()
  if test "$mutating" = yes; then mutation_flag=(--allow-mutating); fi
  local started elapsed
  started="$(python3 -c 'import time; print(time.monotonic_ns())')"
  "$binary" --config "$example/hinagata.yaml" db with --fixture "$fixture" --json -- \
    nix shell "$workbench_ref" -c hurl-workbench \
      --workspace "$example/hurl-workbench.dhall" \
      test suite "$suite" "${mutation_flag[@]}" \
      --variable "service_port=$port" \
      --variable "base_url=http://127.0.0.1:$port" \
      --report json --report-dir "$workspace/reports-$label" \
      > "$workspace/lease-$label.json" 2> "$workspace/run-$label.err"
  elapsed="$(python3 - "$started" <<'PY'
import sys
import time

print((time.monotonic_ns() - int(sys.argv[1])) / 1_000_000)
PY
)"
  printf '%s,%s\n' "$label" "$elapsed" >> "$workspace/suite-times.csv"
  python3 - "$workspace/lease-$label.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["ok"] and result["status"] == 0
assert result["disposition"] == "LeaseReleased"
print(result["leaseId"])
PY
}

export EXAMPLE_SERVICE_START_BARRIER="$workspace/service-start-barrier"
run_suite first default "$first_port" no > "$workspace/first-lease" &
first_suite_pid=$!
run_suite second alternate "$second_port" no service-scenario-alternate > "$workspace/second-lease" &
second_suite_pid=$!
overlap_observed=no
for attempt in $(seq 1 200); do
  live_services=0
  for pid_file in "$workspace"/pids/*; do
    if test -f "$pid_file" && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
      live_services=$((live_services + 1))
    fi
  done
  if test "$live_services" -eq 2; then
    overlap_observed=yes
    break
  fi
  sleep 0.05
done
touch "$EXAMPLE_SERVICE_START_BARRIER"
unset EXAMPLE_SERVICE_START_BARRIER
first_suite_status=0
second_suite_status=0
wait "$first_suite_pid" || first_suite_status=$?
wait "$second_suite_pid" || second_suite_status=$?
test "$overlap_observed" = yes
test "$first_suite_status" -eq 0
test "$second_suite_status" -eq 0
first_lease="$(cat "$workspace/first-lease")"
second_lease="$(cat "$workspace/second-lease")"
test "$first_lease" != "$second_lease"
run_suite command counter-write "$first_port" yes > "$workspace/command-lease"
run_suite generated generated-id "$second_port" yes > "$workspace/generated-lease"

"$binary" --config "$example/hinagata.yaml" db acquire --fixture service-scenario --json > "$workspace/role-lease.json"
read -r role_lease role_database < <(python3 - "$workspace/role-lease.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["ok"] and result["user"] == "hinagata_example_app"
print(result["leaseId"], result["database"])
PY
)
if psql -h "$HINAGATA_TEST_PGHOST" -p "$HINAGATA_TEST_PGPORT" -U hinagata_example_app -d "$role_database" \
  -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -c 'CREATE TABLE public.privileged_operation_must_fail (id int)' \
  > "$workspace/privileged.out" 2> "$workspace/privileged.err"; then
  echo "application role unexpectedly created a table" >&2
  exit 1
fi
rg -q '42501' "$workspace/privileged.err"
"$binary" --config "$example/hinagata.yaml" db release "$role_lease" --json > "$workspace/release-role.json"

for lease in "$first_lease" "$second_lease"; do
  "$binary" --config "$example/hinagata.yaml" inspect "$lease" --json > "$workspace/inspect-$lease.json"
  python3 - "$workspace/inspect-$lease.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["candidate"]["state"] == "Released"
PY
done

service_binary="$EXAMPLE_SERVICE_BINARY"
export EXAMPLE_SERVICE_BINARY=/usr/bin/false
if "$binary" --config "$example/hinagata.yaml" db with --fixture service-scenario --json -- \
  nix shell "$workbench_ref" -c hurl-workbench \
    --workspace "$example/hurl-workbench.dhall" \
    test suite default \
    --variable "service_port=$first_port" \
    --variable "base_url=http://127.0.0.1:$first_port" \
    --report json --report-dir "$workspace/reports-readiness-failure" \
    > "$workspace/lease-readiness-failure.json" 2> "$workspace/run-readiness-failure.err"; then
  echo "unready service unexpectedly passed" >&2
  exit 1
fi
export EXAMPLE_SERVICE_BINARY="$service_binary"
python3 - "$workspace/lease-readiness-failure.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert not result["ok"] and result["status"] > 0
assert result["disposition"] == "LeaseReleased"
PY

export EXAMPLE_SERVICE_READY_FILE="$workspace/cancellation-service-pid"
"$binary" --config "$example/hinagata.yaml" db with --fixture service-scenario --json -- \
  nix shell "$workbench_ref" -c hurl-workbench \
    --workspace "$example/hurl-workbench.dhall" \
    test suite cancellation \
    --variable "service_port=$second_port" \
    --variable "base_url=http://127.0.0.1:$second_port" \
    --report json --report-dir "$workspace/reports-cancellation" \
    > "$workspace/lease-cancellation.json" 2> "$workspace/run-cancellation.err" &
wrapper_pid=$!
for attempt in $(seq 1 150); do
  if test -s "$EXAMPLE_SERVICE_READY_FILE" && curl --max-time 1 -sf "http://127.0.0.1:$second_port/health" > /dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
test -s "$EXAMPLE_SERVICE_READY_FILE"
service_pid="$(cat "$EXAMPLE_SERVICE_READY_FILE")"
kill -INT "$wrapper_pid"
if wait "$wrapper_pid"; then
  echo "cancelled Keiro suite unexpectedly succeeded" >&2
  exit 1
else
  cancellation_status=$?
  test "$cancellation_status" -eq 130
fi
for attempt in $(seq 1 40); do
  if ! kill -0 "$service_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
! kill -0 "$service_pid" 2>/dev/null
python3 - "$workspace/lease-cancellation.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["status"] == 130 and result["child"]["outcome"] == "cancelled"
assert result["disposition"] == "LeaseReleased"
PY

echo "Keiro example passed isolated reads, durable command/read, generated IDs, readiness failure, and cancellation"
cat "$workspace/suite-times.csv"
