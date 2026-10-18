"""Exercise fixture error context through every native CLI lifecycle command."""
import json
import os
from pathlib import Path
import subprocess
import sys

binary, config, directory = sys.argv[1:]
workspace = Path(directory)
fixtures = workspace / "error-fixtures"
fixtures.mkdir()
base = [binary, "--config", config, "--set", "fixture.root=" + str(fixtures), "--set", "project.id=cli-structured-errors", "--set", "setup.password=fixture-password-secret"]
secrets = ("fixture-value-secret", "fixture-copy-secret", "fixture-password-secret", "child-argument-secret")

def write(name, files):
    root = fixtures / name
    root.mkdir()
    for path, content in files.items():
        (root / path).write_text(content)

schema = (workspace / "fixtures/create-table/fixture.sql").read_text() + "\nCREATE TABLE secret_items (id text PRIMARY KEY); CREATE TABLE parent_items (id integer PRIMARY KEY); CREATE TABLE child_items (parent_id integer REFERENCES parent_items(id) DEFERRABLE INITIALLY DEFERRED);\n"
write("create-table", {"fixture.sql": schema})
write("error-sql", {"fixture.yaml": "name: error-sql\nsteps:\n  - sql: first.sql\n  - sql: fail.sql\n", "first.sql": "INSERT INTO secret_items VALUES ('fixture-value-secret');", "fail.sql": "INSERT INTO secret_items VALUES ('fixture-value-secret');"})
write("error-copy", {"fixture.yaml": "name: error-copy\nsteps:\n  - sql: first.sql\n  - copy:\n      table: {schema: public, name: secret_items}\n      columns: [id]\n      file: rows.csv\n      format: csv\n      header: false\n", "first.sql": "INSERT INTO cli_items VALUES (13, 'early write');", "rows.csv": "fixture-copy-secret\nfixture-copy-secret\n"})
write("error-deferred", {"fixture.sql": "INSERT INTO child_items VALUES (404);"})

def call(arguments, extra=(), status=1, json_selected=True):
    result = subprocess.run(base + list(extra) + list(arguments) + (["--json"] if json_selected else []), capture_output=True, text=True, timeout=20)
    assert result.returncode == status, (arguments, result.returncode, result.stdout, result.stderr)
    assert all(secret not in result.stdout + result.stderr for secret in secrets), "secret leaked through CLI diagnostics"
    return json.loads(result.stdout) if json_selected else result

# Caller-owned direct-load tables provide a producer for comparison.
subprocess.run(["psql", "-h", os.environ["HINAGATA_TEST_PGHOST"], "-p", os.environ["HINAGATA_TEST_PGPORT"], "-U", os.environ["HINAGATA_TEST_PGUSER"], "-d", os.environ["HINAGATA_TEST_PGDATABASE"], "-v", "ON_ERROR_STOP=1", "-Atqc", "CREATE TABLE secret_items (id text PRIMARY KEY); CREATE TABLE parent_items (id integer PRIMARY KEY); CREATE TABLE child_items (parent_id integer REFERENCES parent_items(id) DEFERRABLE INITIALLY DEFERRED);"], check=True, stdout=subprocess.DEVNULL)
assert call(["db", "prepare"], status=0)["ok"]
for name, phase, step, state in (("error-sql", "ExecuteSql", 1, "23505"), ("error-copy", "ExecuteCopy", 1, "23505"), ("error-deferred", "CommitLoad", None, "23503")):
    direct = call(["fixture", "load", name, "--target-database", os.environ["HINAGATA_TEST_PGDATABASE"]])["error"]
    expected = direct["loadContext"]
    assert expected["phase"] == phase and expected["stepIndex"] == step and expected["sqlState"] == state, expected
    assert expected["fixture"] == (None if phase == "CommitLoad" else name)
    overlay = workspace / (name + "-baseline.yaml")
    overlay.write_text("baseline:\n  fixtures: [create-table, " + name + "]\n")
    baseline = call(["db", "prepare"], extra=["--config", str(overlay)])["error"]
    assert baseline["phase"] == "baseline-prepare" and baseline["code"] == "baseline_failed", baseline
    errors = [baseline]
    errors.append(call(["db", "acquire", "--fixture", name])["error"])
    # The child must never start; its arguments must not enter error output.
    errors.append(call(["db", "with", "--fixture", name, "--json", "--", "/bin/echo", "child-argument-secret"], json_selected=False))
    with_result = errors.pop()
    errors.append(json.loads(with_result.stdout)["error"])
    validated = call(["fixture", "validate", name])
    errors.append(validated["results"][0]["error"])
    for error in errors:
        assert error["loadContext"] == expected, error
        assert error["sqlState"] == state and error["stepIndex"] == step
        assert error["cleanupFailure"] is None
    assert all(error["code"] == "lease_failed" for error in errors[1:])
plain = call(["db", "acquire", "--fixture", "error-sql"], json_selected=False)
assert "fixture error-sql" in plain.stderr and "step 1" in plain.stderr and "ExecuteSql" in plain.stderr
plain_validation = call(["fixture", "validate", "error-sql"], json_selected=False)
assert "fixture error-sql" in plain_validation.stdout and "step 1" in plain_validation.stdout
print("Structured SQL/COPY/COMMIT lifecycle errors and JSON/plain redaction passed")
