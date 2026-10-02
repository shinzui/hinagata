#!/usr/bin/env bash
set -euo pipefail

binary="$(cabal list-bin hinagata)"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT
mkdir -p "$workspace/fixtures/create-table" "$workspace/fixtures/conflict" "$workspace/bundles"
cat > "$workspace/fixtures/create-table/fixture.sql" <<'SQL'
CREATE TABLE cli_items (id integer PRIMARY KEY, note text NOT NULL);
INSERT INTO cli_items (id, note) VALUES (1, 'first'), (2, 'second');
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

echo "CLI direct-load integration test passed"
