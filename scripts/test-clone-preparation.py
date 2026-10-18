"""Native CLI preparation contract; run inside test-cli-postgres.sh's cluster."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

binary, config, directory = sys.argv[1:]
root = Path(directory) / "preparation with spaces"
root.mkdir()
fixtures = Path(directory) / "fixtures"
base = [binary, "--config", config]


def call(args, extra=(), status=0):
    result = subprocess.run(base + list(extra) + list(args), capture_output=True, text=True, timeout=25)
    assert result.returncode == status, (args, result.returncode, result.stdout, result.stderr)
    if list(args[:2]) == ["db", "acquire"] and "requires-seed" in args and status == 0:
        assert "hinagata-scenario-started" in result.stderr, "scenario marker must be observable"
    return json.loads(result.stdout)


def sql(database, query):
    return subprocess.check_output(
        ["psql", "-h", os.environ["HINAGATA_TEST_PGHOST"], "-p", os.environ["HINAGATA_TEST_PGPORT"],
         "-U", os.environ["HINAGATA_TEST_PGUSER"], "-d", database, "-v", "ON_ERROR_STOP=1", "-Atqc", query], text=True).strip()


def wait_for(predicate, process=None):
    deadline = time.monotonic() + 15
    while not predicate():
        assert time.monotonic() < deadline, "synchronization deadline expired"
        assert process is None or process.poll() is None, "command exited before ready"
        time.sleep(.02)


helper = root / "seed.py"
helper.write_text('''import fcntl, json, os, pathlib, signal, subprocess, sys, time
root, mode, value = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
assert pathlib.Path.cwd() == root.resolve()
assert sys.argv[4:] == ["space argument", "$(touch never-evaluate)"]
assert os.environ["SEED_SECRET"] == "secret-env-sentinel"
assert "PGPASSWORD" not in os.environ
with (root / "lock").open("a+") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    records = list(root.glob("ready-*.json"))
    index = len(records)
    record = dict(index=index, pid=os.getpid(), database=os.environ["PGDATABASE"], password=os.environ.get("PGPASSFILE"))
    (root / ("ready-%d.json" % index)).write_text(json.dumps(record))
if mode == "fail": sys.exit(17)
if mode == "block-drop":
    subprocess.run(["psql", "-v", "ON_ERROR_STOP=1", "-Atqc", "BEGIN; SELECT 1; PREPARE TRANSACTION 'cli_preparation_blocked_drop'"], check=True)
    sys.exit(17)
if mode in ("sleep", "overlap"):
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    if mode == "overlap" and index == 1:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        descendant = subprocess.Popen([sys.executable, "-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)"])
        (root / "descendant").write_text(str(descendant.pid))
    else:
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while not (root / ("release-%d" % index)).exists(): time.sleep(.01)
subprocess.run(["psql", "-v", "ON_ERROR_STOP=1", "-Atqc", "INSERT INTO cli_items VALUES (10, '" + value + "')"], check=True)
''')
consumer = root / "consumer.py"
consumer.write_text('''import os, pathlib, subprocess, sys
pathlib.Path(sys.argv[1]).write_text("started")
value = subprocess.check_output(["psql", "-Atqc", "SELECT note FROM cli_items WHERE id=11"], text=True).strip()
assert value == sys.argv[2], value
''')
scenario = fixtures / "requires-seed"
scenario.mkdir()
(scenario / "fixture.sql").write_text("DO $$ BEGIN RAISE WARNING 'hinagata-scenario-started'; IF NOT EXISTS (SELECT 1 FROM cli_items WHERE id=10) THEN RAISE EXCEPTION 'seed missing'; END IF; END $$; INSERT INTO cli_items SELECT 11, note FROM cli_items WHERE id=10;\n")


def hook(label, mode="seed", value="first", deadline=10000, program=None):
    run = root / label
    run.mkdir()
    overlay = run / "hook.yaml"
    overlay.write_text("clone:\n  preparation:\n    executable: " + json.dumps(program or sys.executable) + "\n    argv: " + json.dumps([str(helper), str(run), mode, value, "space argument", "$(touch never-evaluate)"]) + "\n    cwd: " + json.dumps(str(run)) + "\n    environment: [SEED_SECRET=secret-env-sentinel]\n    deadline_ms: \"" + str(deadline) + "\"\n")
    return run, ["--config", str(overlay), "--set", "setup.password=setup-secret-sentinel"]


def records(run):
    return [json.loads(path.read_text()) for path in sorted(run.glob("ready-*.json"))]


def assert_stopped(run):
    for record in records(run):
        if record["password"]:
            assert not Path(record["password"]).exists()
        try:
            os.kill(record["pid"], 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError(("seed still running", record))
    if (run / "descendant").exists():
        pid = int((run / "descendant").read_text())
        wait_for(lambda: not Path(f"/proc/{pid}").exists()) if sys.platform == "linux" else None
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError(("descendant still running", pid))


warm = call(["db", "prepare", "--json"])
fingerprint = warm["fingerprint"]
maintenance = os.environ["HINAGATA_TEST_PGDATABASE"]
generation = sql(maintenance, "SELECT id FROM hinagata.generations WHERE fingerprint='" + fingerprint + "' AND state='Ready'")
run, selected = hook("native")
assert call(["db", "prepare", "--json"], selected)["result"] == "Reused"
call(["fixture", "plan", "requires-seed", "--json"], selected)
# Loading a caller-owned database remains independent of clone preparation.
call(["fixture", "load", "scenario", "--target-database", maintenance, "--json"], selected)
assert not records(run)
leases = []
for _ in range(2):
    lease = call(["db", "acquire", "--fixture", "requires-seed", "--json"], selected)
    leases.append(lease)
    assert sql(lease["database"], "SELECT note FROM cli_items WHERE id=11") == "first"
    call(["db", "release", lease["leaseId"], "--json"])
assert leases[0]["database"] != leases[1]["database"] and len(records(run)) == 2
assert len({record["database"] for record in records(run)}) == 2

alternate = root / "alternate-seed"
alternate.write_text('#!/bin/sh\nexec python3 "$@"\n')
alternate.chmod(0o700)
for label, value, program in (("changed-argv", "second", None), ("changed-executable", "third", str(alternate))):
    changed, selected = hook(label, value=value, program=program)
    report = call(["db", "prepare", "--json"], selected)
    assert report["result"] == "Reused" and report["fingerprint"] == fingerprint
    marker = changed / "consumer"
    call(["db", "with", "--fixture", "requires-seed", "--json", "--", sys.executable, str(consumer), str(marker), value], selected)
    assert marker.exists() and len(records(changed)) == 1
    assert_stopped(changed)
call(["fixture", "validate", "requires-seed", "--json"], selected)
assert len(records(changed)) == 2
unhooked = call(["db", "acquire", "--json"])
assert sql(unhooked["database"], "SELECT count(*) FROM cli_items WHERE id>=10") == "0"
call(["db", "release", unhooked["leaseId"], "--json"])
assert generation == sql(maintenance, "SELECT id FROM hinagata.generations WHERE fingerprint='" + fingerprint + "' AND state='Ready'")

for label, mode, deadline, overrides, expected, program in (
    ("failure", "fail", 10000, [], "clone_preparation_failed", None),
    ("spawn", "seed", 10000, [], "clone_preparation_failed", "/absent/secret-executable-sentinel"),
    ("hook-timeout", "sleep", 100, [], "clone_preparation_timeout", None),
    ("acquisition-timeout", "sleep", 10000, ["--set", "limits.acquisition_deadline_ms=600"], "clone_preparation_timeout", None),
    ("blocked-drop", "block-drop", 10000, [], "clone_preparation_failed", None),
):
    failed, selected = hook(label, mode, deadline=deadline, program=program)
    marker = failed / "consumer"
    report = call(["db", "with", "--preserve-on-failure", "--json", "--", sys.executable, str(consumer), str(marker), "first"], selected + overrides, status=1)
    error = report["error"]
    assert error["phase"] == "clone-preparation" and error["code"] == expected, report
    assert error["leaseId"] and error["runId"]
    assert not marker.exists()
    assert not any(secret in json.dumps(report) for secret in ("secret-env-sentinel", "secret-executable-sentinel", "setup-secret-sentinel"))
    inspected = call(["inspect", error["leaseId"], "--json"])["candidate"]
    if mode == "block-drop":
        assert inspected["state"] == "CleanupFailed" and "cleanup:" in error["message"]
        sql(inspected["database"], "ROLLBACK PREPARED 'cli_preparation_blocked_drop'")
        call(["db", "release", error["leaseId"], "--json"])
    else:
        assert inspected["state"] == "Released", inspected
    assert_stopped(failed)

# A seed that exits zero in its signal handler still blocks application startup.
for number in (signal.SIGINT, signal.SIGTERM):
    run, selected = hook(f"with-signal-{number}", "sleep")
    marker = run / "consumer"
    process = subprocess.Popen(base + selected + ["db", "with", "--json", "--", sys.executable, str(consumer), str(marker), "first"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wait_for(lambda: len(records(run)) == 1, process)
    process.send_signal(number)
    stdout, stderr = process.communicate(timeout=12)
    assert process.returncode == 128 + number, (stdout, stderr)
    error = json.loads(stdout)["error"]
    assert error["phase"] == "clone-preparation" and error["code"] == "clone_preparation_cancelled"
    assert not marker.exists()
    assert call(["inspect", error["leaseId"], "--json"])["candidate"]["state"] == "Released"
    assert_stopped(run)

# Both signals, both completion orders, and fully overlapping hooks. A third
# selection remains pending; ready/release files avoid timing-based overlap.
for number in (signal.SIGINT, signal.SIGTERM):
    for finish in (None, 0, 1):
        run, selected = hook(f"overlap-{number}-{finish}", "overlap")
        stdout, stderr = (run / "out.json").open("w"), (run / "err").open("w")
        process = subprocess.Popen(base + selected + ["--set", "limits.setup_workers=2", "--set", "limits.active_leases=2", "fixture", "validate", "requires-seed", "requires-seed", "requires-seed", "--json"], stdout=stdout, stderr=stderr)
        try:
            wait_for(lambda: len(records(run)) == 2 and (run / "descendant").exists(), process)
            if finish is not None:
                (run / f"release-{finish}").touch()
                wait_for(lambda: call(["clean", "--json"])["candidates"] and sql(maintenance, "SELECT count(*) FROM hinagata.allocations WHERE database_name='" + records(run)[finish]["database"] + "' AND state='Released'") == "1", process)
            scenario_offset = (run / "err").stat().st_size
            process.send_signal(number)
            # Repeated signals preserve the first signal and the original budget.
            process.send_signal(number)
            assert process.wait(timeout=15) == 128 + number
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            stdout.close()
            stderr.close()
        report = json.loads((run / "out.json").read_text())
        assert len(records(run)) == 2
        assert not report["ok"] and len(report["results"]) == 3
        assert "hinagata-scenario-started" not in (run / "err").read_bytes()[scenario_offset:].decode(), "scenario SQL started after cancellation"
        active = report["results"][:2]
        assert sum(result["ok"] for result in active) == int(finish is not None), report
        assert all(result["ok"] or result["error"]["code"] == "clone_preparation_cancelled" for result in active), report
        pending = report["results"][2]["error"]
        assert pending["code"] == "command_cancelled" and pending["leaseId"] is None
        for record in records(run):
            state = sql(maintenance, "SELECT state FROM hinagata.allocations WHERE database_name='" + record["database"] + "'")
            assert state == "Released", (record, state, report)
        assert_stopped(run)
print("clone preparation passed ordering, reuse, failures, deadlines, blocked drop, and concurrent INT/TERM cancellation")
