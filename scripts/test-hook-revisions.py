"""Real cache invalidation and stable-input boundary checks on a disposable cluster."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

binary, original_config, directory = sys.argv[1:]
root = Path(directory) / "revisions with spaces"
root.mkdir()
config = root / "base.yaml"
config.write_text(Path(original_config).read_text().replace("  revision: cli-migration-v1\n", "").replace("  revision: cli-verification-v1\n", ""))
overlay = root / "inputs.yaml"
source = root / "external=sql.sql"
source.write_text("CREATE TABLE declared_sql (id integer); -- content-sentinel\n")
verify_source = root / "verify.sql"
verify_source.write_text("SELECT count(*) FROM declared_sql;\n")
program = root / "driver.py"
program.write_text('''import os, pathlib, subprocess, sys
root = pathlib.Path.cwd()
with (root / "invocations").open("a") as out: out.write(sys.argv[1] + "\\n")
if (root / "mutation").exists():
    mode = (root / "mutation").read_text()
    selected = root / "verify.sql"
    if mode == "delete": selected.unlink()
    else: selected.write_text(selected.read_text() + "-- observed mutation\\n")
    if mode == "fail": sys.exit(19)
subprocess.run(["psql", "-v", "ON_ERROR_STOP=1", "-f", str(root / ("external=sql.sql" if sys.argv[1] == "migration" else "verify.sql"))], check=True, stdout=subprocess.DEVNULL)
''')
base = [binary, "--config", str(config), "--config", str(overlay)]


def declarations(manual=(), missing=()):
    text = ""
    for hook in ("migration", "verification"):
        text += hook + ":\n  executable: " + json.dumps(sys.executable) + "\n  argv: " + json.dumps([str(program), hook]) + "\n  cwd: " + json.dumps(str(root)) + "\n"
        if hook in manual:
            text += "  revision: regression-manual-v1\n"
        elif hook not in missing:
            text += "  revision_executable: true\n  revision_inputs: " + json.dumps(["driver=" + str(program), "application/sql=external=sql.sql", "verification/sql=verify.sql"]) + "\n  revision_values: [\"marker=literal-sentinel=extra\"]\n"
    overlay.write_text(text)


def call(args=("db", "prepare", "--json"), status=0):
    result = subprocess.run(base + list(args), capture_output=True, text=True, timeout=30)
    assert result.returncode == status, (result.returncode, result.stdout, result.stderr)
    output = result.stdout
    for private in (str(source), str(verify_source), "content-sentinel", "literal-sentinel"):
        assert private not in output, output
    return json.loads(output)


def pair():
    built, reused = call(), call()
    assert (built["result"], reused["result"]) == ("Built", "Reused"), (built, reused)
    assert built["fingerprint"] == reused["fingerprint"]
    return built


def sql(database, query):
    return subprocess.check_output(["psql", "-h", os.environ["HINAGATA_TEST_PGHOST"], "-p", os.environ["HINAGATA_TEST_PGPORT"], "-U", os.environ["HINAGATA_TEST_PGUSER"], "-d", database, "-v", "ON_ERROR_STOP=1", "-Atqc", query], text=True).strip()


def invocations():
    return (root / "invocations").read_text() if (root / "invocations").exists() else ""


def capture_failure(expected="hook_revision_input_unreadable"):
    before = invocations()
    failure = call(status=1)
    assert failure["error"]["phase"] == "hook-revision" and failure["error"]["code"] == expected, failure
    assert invocations() == before, "initial capture failure must run neither hook"


declarations()
# Broken input before even the first generation.
verify_source.unlink()
capture_failure()
verify_source.write_text("SELECT count(*) FROM declared_sql;\n")
first = pair()
original_digest = hashlib.sha256(program.read_bytes()).digest()
source.write_text("CREATE TABLE declared_sql (id integer, added text); -- content-sentinel\n")
changed = pair()
assert original_digest == hashlib.sha256(program.read_bytes()).digest()
assert first["fingerprint"] != changed["fingerprint"]
lease = call(("db", "acquire", "--json"))
assert sql(lease["database"], "SELECT count(*) FROM information_schema.columns WHERE table_name='declared_sql' AND column_name='added'") == "1"
call(("db", "release", lease["leaseId"], "--json"))
verify_source.write_text(verify_source.read_text() + "-- verification-only bytes\n")
pair()
# Failures after a matching Ready generation exists cannot be hidden by reuse.
for selected in (source, verify_source):
    saved = selected.read_bytes()
    selected.unlink()
    capture_failure()
    selected.write_bytes(saved)
    assert os.geteuid() != 0, "permission check requires unprivileged process"
    selected.chmod(0)
    try:
        capture_failure()
    finally:
        selected.chmod(0o600)
    assert call()["result"] == "Reused"
# Each missing revision disables persistent reuse; both manual and mixed work.
for absent in ("migration", "verification"):
    declarations(manual=("verification" if absent == "migration" else "migration",), missing=(absent,))
    assert call()["result"] == call()["result"] == "Built"
declarations(manual=("migration", "verification"))
pair()
for manual in ("migration", "verification"):
    declarations(manual=(manual,))
    pair()
declarations()
# Mutation of the other hook's inputs must fail before publication.
for mode in ("change", "delete", "fail"):
    source.write_text(source.read_text() + "-- unique " + mode + "\n")
    saved = verify_source.read_bytes()
    (root / "mutation").write_text(mode)
    failure = call(status=1)
    assert failure["error"]["code"] == ("baseline_failed" if mode == "fail" else "hook_revision_inputs_changed"), failure
    (root / "mutation").unlink()
    verify_source.write_bytes(saved)
    pair()
# A caller waiting on the fingerprint lock must recheck before returning Reused.
ready = call()
maintenance = os.environ["HINAGATA_TEST_PGDATABASE"]
project = "cli-direct-load"
lock_name = project + ":" + ready["fingerprint"]
psql = subprocess.Popen(["psql", "-h", os.environ["HINAGATA_TEST_PGHOST"], "-p", os.environ["HINAGATA_TEST_PGPORT"], "-U", os.environ["HINAGATA_TEST_PGUSER"], "-d", maintenance, "-Atq"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
psql.stdin.write("SELECT pg_advisory_lock(1212761905, hashtext('" + lock_name + "'));\n\\echo LOCKED\n")
psql.stdin.flush()
while psql.stdout.readline().strip() != "LOCKED":
    assert psql.poll() is None
waiting = subprocess.Popen(base + ["db", "prepare", "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    deadline = time.monotonic() + 10
    while sql(maintenance, "SELECT count(*) FROM pg_stat_activity WHERE wait_event='advisory' AND query LIKE '%pg_advisory_lock(1212761905%'") == "0":
        assert time.monotonic() < deadline and waiting.poll() is None
        time.sleep(.02)
    source.write_text(source.read_text() + "-- changed during lock wait\n")
finally:
    psql.communicate("\\q\n", timeout=10)
out, err = waiting.communicate(timeout=20)
assert waiting.returncode == 1, (out, err)
assert json.loads(out)["error"]["code"] == "hook_revision_inputs_changed", out
pair()
print("Declared-input native cache, redaction, mutation, and lock-wait checks passed")
