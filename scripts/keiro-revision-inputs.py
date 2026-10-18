"""Generate consumed identity declarations and exercise independent example inputs."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

mode, binary, example_path, migration_binary, directory = sys.argv[1:]
example, root = Path(example_path), Path(directory)
work = root / "declared-inputs"
overlay = root / "revision-inputs.yaml"
marker = "example-v1's \\ marker"


def write_overlay(value=marker):
    # Every command overlay and corresponding identity selector share these paths
    # and this marker variable. Neither declaration discovers transitive files.
    manifest = work / "migration" / "manifest.json"
    sql = work / "migration" / "application.sql"
    program = work / "migrate"
    verification = work / "migration" / "verify.sh"
    shared = ["application/sql=" + str(sql), "application/manifest=" + str(manifest)]
    environment = ["EXAMPLE_MIGRATION_MANIFEST=" + str(manifest), "EXAMPLE_SCHEMA_MARKER=" + value]
    text = ""
    for hook in ("migration", "verification"):
        selected = program if hook == "migration" else verification
        files = shared if hook == "migration" else shared + ["verification/program=" + str(program), "verification/sql=" + str(work / "migration" / "verify.sql")]
        env = environment if hook == "migration" else environment + ["EXAMPLE_VERIFY_BINARY=" + str(program)]
        text += hook + ":\n  executable: " + json.dumps(str(selected)) + "\n  argv: " + json.dumps(["up"] if hook == "migration" else []) + "\n  cwd: " + json.dumps(str(work)) + "\n  environment: " + json.dumps(env) + "\n  revision_executable: true\n  revision_inputs: " + json.dumps(files) + "\n  revision_values: " + json.dumps(["schema-marker=" + value]) + "\n"
    overlay.write_text(text)


if mode == "write":
    work.mkdir()
    shutil.copytree(example / "migration", work / "migration")
    shutil.copy2(migration_binary, work / "migrate")
    write_overlay()
    sys.exit(0)
assert mode == "test"
base = [binary, "--config", str(example / "hinagata.yaml"), "--config", str(overlay)]


def call(args=("db", "prepare", "--json"), status=0):
    result = subprocess.run(base + list(args), capture_output=True, text=True, timeout=150)
    assert result.returncode == status, (args, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)


def sql(database, statement):
    return subprocess.check_output(["psql", "-h", os.environ["HINAGATA_TEST_PGHOST"], "-p", os.environ["HINAGATA_TEST_PGPORT"], "-U", os.environ["HINAGATA_TEST_PGUSER"], "-d", database, "-v", "ON_ERROR_STOP=1", "-Atqc", statement], text=True).strip()


originals = {path: path.read_bytes() for path in work.rglob("*") if path.is_file()}
normal = call()
assert normal["result"] == "Reused"
for kind in ("executable", "sql", "manifest", "verification-script", "verification-sql", "value"):
    for path, content in originals.items():
        path.write_bytes(content)
    write_overlay()
    assert call()["result"] == "Reused"
    digest_before = hashlib.sha256((work / "migrate").read_bytes()).digest()
    if kind == "executable":
        with (work / "migrate").open("ab") as out:
            out.write(b"\0inert-hinagata-identity-variant\0")
        # Verify this platform can run the temporary altered binary before using it.
        env = dict(os.environ, EXAMPLE_MIGRATION_MANIFEST=str(work / "migration" / "manifest.json"), EXAMPLE_SCHEMA_MARKER=marker,
                   PGHOST=os.environ["HINAGATA_TEST_PGHOST"], PGPORT=os.environ["HINAGATA_TEST_PGPORT"], PGUSER=os.environ["HINAGATA_TEST_PGUSER"], PGDATABASE=os.environ["HINAGATA_TEST_PGDATABASE"])
        probe = subprocess.run([str(work / "migrate"), "probe"], env=env, capture_output=True, text=True)
        assert probe.returncode == 1 and "usage:" in probe.stderr, probe
        assert digest_before != hashlib.sha256((work / "migrate").read_bytes()).digest()
    elif kind == "sql":
        with (work / "migration" / "application.sql").open("a") as out:
            out.write("\nALTER TABLE public.keiro_reference_data ADD COLUMN external_sql_variant text;\n")
    elif kind == "manifest":
        manifest = work / "migration" / "manifest.json"
        data = json.loads(manifest.read_text())
        data["id"] = "create-reference-data-variant"
        manifest.write_text(json.dumps(data))
    elif kind.startswith("verification"):
        path = work / "migration" / ("verify.sh" if kind.endswith("script") else "verify.sql")
        with path.open("a") as out:
            out.write("\n# verification program variant\n" if kind.endswith("script") else "\n-- verification SQL variant\n")
    else:
        write_overlay("example-v2's \\ marker")
    built, repeat = call(), call()
    assert built["result"] == "Built" and repeat["result"] == "Reused", (kind, built, repeat)
    assert built["fingerprint"] != normal["fingerprint"]
    if kind == "sql":
        assert digest_before == hashlib.sha256((work / "migrate").read_bytes()).digest()
    if kind in ("sql", "manifest", "value"):
        lease = call(("db", "acquire", "--json"))
        try:
            assert sql(lease["database"], "SELECT count(*) FROM public.keiro_reference_data") == "2"
            expected_marker = "example-v2's \\ marker" if kind == "value" else marker
            assert sql(lease["database"], "SELECT obj_description('public.keiro_reference_data'::regclass)") == expected_marker
            if kind == "sql":
                assert sql(lease["database"], "SELECT count(*) FROM information_schema.columns WHERE table_name='keiro_reference_data' AND column_name='external_sql_variant'") == "1"
            if kind == "manifest":
                # Verification has recomputed and checked the complete changed ledger.
                assert call()["result"] == "Reused"
        finally:
            call(("db", "release", lease["leaseId"], "--json"))
    print("Keiro declared " + kind + ": Reused -> Built -> Reused")
for path, content in originals.items():
    path.write_bytes(content)
write_overlay()
assert call()["result"] == "Reused"
# Failure proves the wrapper and its SQL really run; a stale environment binding
# to the old verifier would incorrectly let this preparation succeed.
check = work / "migration" / "verify.sql"
check.write_text("DO $$ BEGIN RAISE EXCEPTION 'verification wrapper probe'; END $$;\n")
assert call(status=1)["error"]["code"] == "baseline_failed"
check.write_bytes(originals[check])
assert call()["result"] == "Reused"
