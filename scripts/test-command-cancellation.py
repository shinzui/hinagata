"""Signal native CLI work only after PostgreSQL confirms its blocking point."""
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

binary, config, workspace = sys.argv[1:]
root = pathlib.Path(workspace)
env = os.environ.copy()
env.update({"PGHOST": env["HINAGATA_TEST_PGHOST"], "PGPORT": env["HINAGATA_TEST_PGPORT"], "PGUSER": env["HINAGATA_TEST_PGUSER"], "PGDATABASE": env["HINAGATA_TEST_PGDATABASE"]})

def sql(statement):
    return subprocess.check_output(["psql", "-X", "-Atqc", statement], env=env, text=True).strip()

def wait_for(statement, child):
    expiry = time.monotonic() + 10
    while sql(statement) == "0":
        assert child.poll() is None, "command exited before barrier"
        assert time.monotonic() < expiry, "PostgreSQL barrier timed out"
        time.sleep(.02)

fixture = root / "cancellation-fixtures" / "cancel-native"
fixture.mkdir(parents=True)
(fixture / "fixture.sql").write_text("UPDATE cli_items SET note='cancelled-native-secret' WHERE id=1; SELECT pg_sleep(30); INSERT INTO cli_items VALUES (900, 'after cancellation');")
for sig in (signal.SIGINT, signal.SIGTERM):
    child = subprocess.Popen([binary, "--config", config, "--set", "fixture.root=" + str(fixture.parent), "fixture", "load", "cancel-native", "--target-database", env["PGDATABASE"], "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_for("SELECT count(*) FROM pg_stat_activity WHERE wait_event='PgSleep' AND query LIKE 'UPDATE cli_items SET note=%'", child)
        started = time.monotonic()
        child.send_signal(sig)
        # The first signal owns cleanup; repeated signals must not interrupt it.
        child.send_signal(sig)
        out, err = child.communicate(timeout=8)
        assert child.returncode == 128 + sig, (child.returncode, out, err)
        assert time.monotonic() - started < 8
        result = json.loads(out)
        assert result["ok"] is False and result["error"]["code"] == "command_cancelled", result
        assert "cancelled-native-secret" not in out + err
        assert sql("SELECT count(*) FROM cli_items WHERE id=1 AND note='first'") == "1"
        assert sql("SELECT count(*) FROM cli_items WHERE id=900") == "0"
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate()

# Block a prepared generation lock, then cancel prepare and clone acquisition.
ready = json.loads(subprocess.check_output([binary, "--config", config, "db", "prepare", "--json"], text=True))
key = "cli-direct-load:" + ready["fingerprint"]
controller = subprocess.Popen(["psql", "-X", "-At"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
try:
    controller.stdin.write("SELECT pg_advisory_lock(1212761905, hashtext('" + key + "'));\n\\echo LOCKED\n")
    controller.stdin.flush()
    while controller.stdout.readline().strip() != "LOCKED":
        assert controller.poll() is None
    for command in (["db", "prepare"], ["db", "acquire"]):
        child = subprocess.Popen([binary, "--config", config, *command, "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for("SELECT count(*) FROM pg_stat_activity WHERE wait_event='advisory' AND query LIKE '%pg_advisory_lock(1212761905%'", child)
            child.send_signal(signal.SIGTERM)
            out, err = child.communicate(timeout=8)
            assert child.returncode == 143, (out, err)
            assert json.loads(out)["ok"] is False
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()
finally:
    controller.stdin.close()
    controller.wait(timeout=5)
print("Native direct-load and catalog-wait INT/TERM cancellation passed")
