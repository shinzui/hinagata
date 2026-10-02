#!/usr/bin/env bash
set -euo pipefail

binary="$(cabal list-bin hinagata)"
export hinagata_postgres_datadir="$(pwd)/hinagata-postgres"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT
mkdir -p "$workspace/fixtures/create-table" "$workspace/fixtures/conflict" "$workspace/bundles"
mkdir -p "$workspace/fixtures/scenario"
cat > "$workspace/fixtures/create-table/fixture.sql" <<'SQL'
CREATE TABLE cli_items (id integer PRIMARY KEY, note text NOT NULL);
INSERT INTO cli_items (id, note) VALUES (1, 'first'), (2, 'second');
SQL
cat > "$workspace/fixtures/scenario/fixture.sql" <<'SQL'
INSERT INTO cli_items (id, note) VALUES (3, 'isolated scenario');
SQL
cat > "$workspace/fixtures/conflict/fixture.sql" <<'SQL'
INSERT INTO cli_items (id, note) VALUES (3, 'temporary');
INSERT INTO cli_items (id, note) VALUES (1, 'duplicate');
SQL

cat > "$workspace/hinagata.yaml" <<EOF
endpoint:
  host: $HINAGATA_TEST_PGHOST
  port: $HINAGATA_TEST_PGPORT
project:
  id: cli-direct-load
fixture:
  root: $workspace/fixtures
bundle:
  root: $workspace/bundles
maintenance:
  database: $HINAGATA_TEST_PGDATABASE
administration:
  user: $HINAGATA_TEST_PGUSER
  database: $HINAGATA_TEST_PGDATABASE
setup:
  user: $HINAGATA_TEST_PGUSER
  database: $HINAGATA_TEST_PGDATABASE
application:
  user: $HINAGATA_TEST_PGUSER
  database: $HINAGATA_TEST_PGDATABASE
baseline:
  fixtures: [create-table]
migration:
  executable: $(command -v cat)
  revision: cli-migration-v1
verification:
  executable: $(command -v cat)
  revision: cli-verification-v1
EOF

"$binary" --config "$workspace/hinagata.yaml" fixture load create-table --target-database "$HINAGATA_TEST_PGDATABASE" --json > "$workspace/load.json"
count="$(psql -h "$HINAGATA_TEST_PGHOST" -p "$HINAGATA_TEST_PGPORT" -U "$HINAGATA_TEST_PGUSER" -d "$HINAGATA_TEST_PGDATABASE" -Atqc 'SELECT count(*) FROM cli_items')"
test "$count" = 2

python3 - "$workspace/load.json" "$HINAGATA_TEST_PGDATABASE" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["formatVersion"] == 1 and result["ok"] is True
assert result["kind"] == "fixture-load" and result["database"] == sys.argv[2]
assert result["fixtureCount"] == 1 and result["stepCount"] == 1
assert result["bytesSent"] > 0
PY

if "$binary" --config "$workspace/hinagata.yaml" fixture load conflict --target-database "$HINAGATA_TEST_PGDATABASE" --json > "$workspace/conflict.json" 2> "$workspace/conflict.err"; then
  echo "duplicate-key fixture unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  test "$status" -eq 1
fi

python3 - "$workspace/conflict.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["formatVersion"] == 1 and result["ok"] is False
assert result["error"]["code"] == "load_failed"
assert result["error"]["phase"] == "ExecuteSql"
assert result["error"]["fixture"] == "conflict"
assert result["error"]["sqlState"] == "23505"
PY

count="$(psql -h "$HINAGATA_TEST_PGHOST" -p "$HINAGATA_TEST_PGPORT" -U "$HINAGATA_TEST_PGUSER" -d "$HINAGATA_TEST_PGDATABASE" -Atqc 'SELECT count(*) FROM cli_items')"
test "$count" = 2

"$binary" --config "$workspace/hinagata.yaml" db prepare --json > "$workspace/prepare-cold.json"
"$binary" --config "$workspace/hinagata.yaml" db prepare --json > "$workspace/prepare-warm.json"
python3 - "$workspace/prepare-cold.json" "$workspace/prepare-warm.json" <<'PY'
import json
import pathlib
import sys

cold, warm = (json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:])
assert cold["ok"] and cold["result"] == "Built"
assert warm["ok"] and warm["result"] == "Reused"
assert cold["fingerprint"] == warm["fingerprint"]
assert cold["reason"] == "no-matching-ready-generation"
assert warm["reason"] == "matching-sealed-generation"
assert "BaseFixtures" in cold["fingerprintCategories"]
assert "MigrationRevision" in cold["fingerprintCategories"]
PY

"$binary" --config "$workspace/hinagata.yaml" db acquire --fixture scenario --json > "$workspace/acquire.json"
read -r lease_id database_name < <(python3 - "$workspace/acquire.json" <<'PY'
import json
import pathlib
import sys

acquired = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert acquired["ok"] and acquired["kind"] == "db-acquire"
assert acquired["timingsMs"]["scenarioLoad"] >= 0
print(acquired["leaseId"], acquired["database"])
PY
)
count="$(psql -h "$HINAGATA_TEST_PGHOST" -p "$HINAGATA_TEST_PGPORT" -U "$HINAGATA_TEST_PGUSER" -d "$database_name" -Atqc 'SELECT count(*) FROM cli_items')"
test "$count" = 3
"$binary" --config "$workspace/hinagata.yaml" inspect "$lease_id" --json > "$workspace/inspect.json"
"$binary" --config "$workspace/hinagata.yaml" db release "$lease_id" --json > "$workspace/release.json"
"$binary" --config "$workspace/hinagata.yaml" inspect "$lease_id" --json > "$workspace/inspect-released.json"
python3 - "$workspace/inspect.json" "$workspace/release.json" "$workspace/inspect-released.json" <<'PY'
import json
import pathlib
import sys

before, released, after = (json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:])
assert before["candidate"]["disposition"] == "Retained"
assert released["ok"] and released["results"][0]["outcome"].startswith("released ")
assert after["candidate"]["disposition"] == "Missing"
PY

"$binary" --config "$workspace/hinagata.yaml" db acquire --fixture scenario --json > "$workspace/cleanup-acquire.json"
cleanup_lease="$(python3 - "$workspace/cleanup-acquire.json" <<'PY'
import json
import pathlib
import sys

print(json.loads(pathlib.Path(sys.argv[1]).read_text())["leaseId"])
PY
)"
"$binary" --config "$workspace/hinagata.yaml" inspect "$cleanup_lease" --json > "$workspace/cleanup-inspect.json"
cleanup_allocation="$(python3 - "$workspace/cleanup-inspect.json" <<'PY'
import json
import pathlib
import sys

print(json.loads(pathlib.Path(sys.argv[1]).read_text())["candidate"]["allocationId"])
PY
)"
"$binary" --config "$workspace/hinagata.yaml" clean --json > "$workspace/cleanup-preview.json"
if "$binary" --config "$workspace/hinagata.yaml" clean --apply --id "$cleanup_allocation" --json > "$workspace/cleanup-refused.json"; then
  echo "retained cleanup without selection policy unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  test "$status" -eq 1
fi
"$binary" --config "$workspace/hinagata.yaml" clean --apply --include-retained --id "$cleanup_allocation" --json > "$workspace/cleanup-applied.json"
python3 - "$workspace/cleanup-preview.json" "$workspace/cleanup-refused.json" "$workspace/cleanup-applied.json" "$cleanup_allocation" <<'PY'
import json
import pathlib
import sys

preview, refused, applied = (json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:4])
allocation = sys.argv[4]
assert any(item["allocationId"] == allocation and item["disposition"] == "Retained" for item in preview["candidates"])
assert not refused["ok"] and refused["results"][0]["outcome"].startswith("skipped ")
assert applied["ok"] and applied["results"][0]["outcome"].startswith("released ")
PY

"$binary" --config "$workspace/hinagata.yaml" db with --fixture scenario --json -- "$(command -v psql)" -Atqc 'SELECT count(*) FROM cli_items' > "$workspace/with-success.json" 2> "$workspace/with-success.err"
test "$(tr -d '\n' < "$workspace/with-success.err")" = 3
python3 - "$workspace/with-success.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["ok"] and result["status"] == 0
assert result["child"]["exitCode"] == 0
assert result["disposition"] == "LeaseReleased"
PY

HINAGATA_ADMINISTRATION_PASSWORD=admin-sentinel HINAGATA_SETUP_PASSWORD=setup-sentinel PGPASSWORD=ambient-sentinel \
  "$binary" --config "$workspace/hinagata.yaml" --set application.password=application-sentinel \
    db with --fixture scenario --json -- python3 -c '
import os
import pathlib
import stat
import sys

variables = os.environ
assert "PGPASSWORD" not in variables
assert "HINAGATA_ADMINISTRATION_PASSWORD" not in variables
assert "HINAGATA_SETUP_PASSWORD" not in variables
assert sorted(key for key in variables if key.startswith("HINAGATA_")) == ["HINAGATA_LEASE_ID", "HINAGATA_RUN_ID"]
assert all(variables[key] for key in ("PGHOST", "PGPORT", "PGUSER", "PGDATABASE"))
path = pathlib.Path(variables["PGPASSFILE"])
assert path.is_file() and stat.S_IMODE(path.stat().st_mode) == 0o600
pathlib.Path(sys.argv[1]).write_text(str(path))
' "$workspace/password-path" > "$workspace/with-password.json" 2> "$workspace/with-password.err"
password_path="$(cat "$workspace/password-path")"
test ! -e "$password_path"
python3 - "$workspace/with-password.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["ok"] and result["disposition"] == "LeaseReleased"
PY

if "$binary" --config "$workspace/hinagata.yaml" db with --fixture scenario --preserve-on-failure --json -- "$(command -v sh)" -c 'exit 17' > "$workspace/with-failure.json" 2> "$workspace/with-failure.err"; then
  echo "failing child unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  test "$status" -eq 17
fi
read -r failed_lease failed_run < <(python3 - "$workspace/with-failure.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert not result["ok"] and result["status"] == 17
assert result["disposition"] == "LeasePreserved"
print(result["leaseId"], result["runId"])
PY
)
"$binary" --config "$workspace/hinagata.yaml" inspect "$failed_lease" --json > "$workspace/with-preserved.json"
python3 - "$workspace/with-preserved.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["candidate"]["disposition"] == "Retained"
PY
"$binary" --config "$workspace/hinagata.yaml" db release "$failed_lease" --json > "$workspace/with-preserved-release.json"

"$binary" --config "$workspace/hinagata.yaml" fixture validate scenario --json > "$workspace/validate-one.json"
if "$binary" --config "$workspace/hinagata.yaml" fixture validate --all --json > "$workspace/validate-all.json"; then
  echo "validation with a conflicting scenario unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  test "$status" -eq 1
fi
python3 - "$workspace/validate-one.json" "$workspace/validate-all.json" <<'PY'
import json
import pathlib
import sys

one, all_results = (json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:])
assert one["ok"] and [item["scenario"] for item in one["results"]] == ["scenario"]
assert not all_results["ok"]
assert [item["scenario"] for item in all_results["results"]] == ["conflict", "create-table", "scenario"]
assert [item["ok"] for item in all_results["results"]] == [False, True, True]
assert all_results["results"][0]["error"]["code"] == "lease_failed"
PY

"$binary" --config "$workspace/hinagata.yaml" db with --fixture scenario --json -- "$(command -v sh)" -c 'trap "" TERM INT; sleep 30 & echo "$$ $!" > "$1"; wait' sh "$workspace/child-pids" > "$workspace/with-cancelled.json" 2> "$workspace/with-cancelled.err" &
wrapper_pid=$!
for attempt in $(seq 1 100); do
  test -s "$workspace/child-pids" && break
  sleep 0.1
done
test -s "$workspace/child-pids"
read -r child_pid descendant_pid < "$workspace/child-pids"
kill -TERM "$wrapper_pid"
if wait "$wrapper_pid"; then
  echo "cancelled wrapper unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  if test "$status" -ne 143; then
    cat "$workspace/with-cancelled.json" "$workspace/with-cancelled.err" >&2
  fi
  test "$status" -eq 143
fi
for attempt in $(seq 1 40); do
  if ! kill -0 "$child_pid" 2>/dev/null && ! kill -0 "$descendant_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
! kill -0 "$child_pid" 2>/dev/null
! kill -0 "$descendant_pid" 2>/dev/null
cancelled_lease="$(python3 - "$workspace/with-cancelled.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["status"] == 143 and result["child"]["outcome"] == "cancelled"
assert result["disposition"] == "LeaseReleased"
print(result["leaseId"])
PY
)"
"$binary" --config "$workspace/hinagata.yaml" inspect "$cancelled_lease" --json > "$workspace/inspect-cancelled.json"
python3 - "$workspace/inspect-cancelled.json" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert result["candidate"]["state"] == "Released"
PY

echo "CLI direct-load integration test passed"
