#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
binary="$(cabal list-bin hinagata)"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT
mkdir -p "$workspace/fixtures/seeded-member" "$workspace/bundles"
printf 'SELECT 1;\n' > "$workspace/fixtures/seeded-member/fixture.sql"

cat > "$workspace/base.yaml" <<EOF
endpoint:
  host: /nonexistent/hinagata-socket
  port: 5432
project:
  id: cli-offline
fixture:
  root: $workspace/fixtures
bundle:
  root: $workspace/bundles
maintenance:
  database: postgres
administration:
  user: cli_admin
  database: postgres
setup:
  user: cli_setup
  database: postgres
application:
  user: cli_app
  database: postgres
EOF

"$binary" --config "$workspace/absent.yaml" --describe-config-json > "$workspace/schema.json"
"$binary" --config "$workspace/absent.yaml" --help > "$workspace/help.txt"
"$binary" --config "$workspace/absent.yaml" --version > "$workspace/version.txt"
"$binary" --config "$workspace/base.yaml" --check-config > "$workspace/check.txt"
"$binary" --config "$workspace/base.yaml" fixture plan seeded-member --json > "$workspace/plan.json"
"$binary" --config "$workspace/absent.yaml" completions bash > "$workspace/bash-completion"
"$binary" --bash-completion-index 2 --bash-completion-word hinagata --bash-completion-word fixture --bash-completion-word '' > "$workspace/nested-completion"

python3 - "$workspace" <<'PY'
import json
import pathlib
import sys

workspace = pathlib.Path(sys.argv[1])
schema = json.loads((workspace / "schema.json").read_text())
plan = json.loads((workspace / "plan.json").read_text())
assert schema["schemaVersion"] == 1
assert any(item["key"] == "administration.password" and item["sensitivity"] == "secret" for item in schema["settings"])
assert plan["formatVersion"] == 1 and plan["ok"] is True
assert [fixture["name"] for fixture in plan["fixtures"]] == ["seeded-member"]
assert plan["fixtures"][0]["steps"][0]["type"] == "sql"
assert (workspace / "check.txt").read_text().strip() == "configuration valid"
assert "fixture" in (workspace / "help.txt").read_text()
assert "revision unavailable" in (workspace / "version.txt").read_text()
assert "--bash-completion-word" in (workspace / "bash-completion").read_text()
assert "plan" in (workspace / "nested-completion").read_text().splitlines()
PY

if "$binary" --config "$workspace/base.yaml" --set administration.password=sentinel-secret --set endpoint.port=0 --explain-config-json fixture plan seeded-member --json > "$workspace/invalid.json" 2> "$workspace/invalid.err"; then
  echo "invalid configuration unexpectedly succeeded" >&2
  exit 1
else
  status=$?
  test "$status" -eq 4
fi

if rg -q 'sentinel-secret' "$workspace/invalid.json" "$workspace/invalid.err"; then
  echo "secret leaked from a failed configuration resolution" >&2
  exit 1
fi

python3 - "$workspace/invalid.json" <<'PY'
import json
import pathlib
import sys

failure = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert failure["formatVersion"] == 1
assert failure["error"]["code"] == "config_resolution_invalid"
PY

echo "CLI offline smoke test passed"
