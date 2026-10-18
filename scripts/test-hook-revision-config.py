"""Offline declared-input configuration and redaction contract."""
import json
import os
from pathlib import Path
import subprocess
import sys

binary, directory = sys.argv[1:]
root = Path(directory)
base = [binary, "--config", str(root / "base.yaml")]
settings = {s["key"]: s for s in json.loads((root / "schema.json").read_text())["settings"]}
for hook in ("migration", "verification"):
    for key in ("revision_executable", "revision_inputs", "revision_values"):
        assert hook + "." + key in settings
        assert "clone.preparation." + key not in settings
    for key in ("revision_inputs", "revision_values"):
        assert settings[hook + "." + key]["sensitivity"] == "secret"

overlay = root / "revision.yaml"
private = "/private/selected-path-sentinel.sql"

def write(body):
    overlay.write_text("migration:\n" + "\n".join("  " + line for line in body.splitlines()) + "\n")


def run(mode="--check-config", extra=(), status=0, env=None):
    result = subprocess.run(base + ["--config", str(overlay)] + list(extra) + [mode], capture_output=True, text=True, env=env, timeout=10)
    assert result.returncode == status, result
    output = result.stdout + result.stderr
    for sentinel in (private, "literal-value-sentinel", "malformed-entry-sentinel"):
        assert sentinel not in output, output
    return result

valid = 'executable: /nonexistent/migrate\nrevision_executable: true\nrevision_inputs: ["sql=' + private + '"]\nrevision_values: ["config=literal-value-sentinel=a", "empty="]'
write(valid)
for mode in ("--check-config", "--explain-config", "--explain-config-json"):
    run(mode)
# Final arrays replace earlier arrays, including clearing, rather than merging.
clear = root / "clear.yaml"
clear.write_text('migration:\n  revision_inputs: []\n  revision_values: []\n  revision_executable: false\n  revision: manual\n')
run(extra=["--config", str(clear)])
replace = root / "replace.yaml"
replace.write_text('migration:\n  revision_inputs: ["sql=elsewhere.sql"]\n  revision_values: ["config=replaced"]\n')
run(extra=["--config", str(replace)])
for key in ("revision_inputs", "revision_values"):
    run(extra=["--set", "migration." + key + "=[]"], status=4)
for body in (
    'revision_inputs: ["sql=a"]',
    'executable: /bin/true\nrevision: ""\nrevision_values: ["config=literal-value-sentinel"]',
    'executable: /bin/true\nrevision: manual\nrevision_executable: true',
    'executable: basename\nrevision_executable: true',
    'executable: /bin/true\nrevision_inputs: ["malformed-entry-sentinel"]',
    'executable: /bin/true\nrevision_values: ["INVALID=literal-value-sentinel"]',
    'executable: /bin/true\nrevision_inputs: ["sql=a", "sql=b"]',
    'executable: /bin/true\nrevision_inputs: ["sql=a"]\nrevision_values: ["sql=b"]',
    'executable: /bin/true\nrevision_executable: true\nrevision_inputs: ["executable=a"]',
    'executable: /bin/true\nrevision_inputs: ["sql="]',
    'executable: /bin/true\nrevision_inputs: ["sql=a\\0b"]',
):
    write(body)
    run(status=4)
write('executable: basename\nrevision_executable: false\nrevision_values: ["config=literal-value-sentinel"]')
run()
# Scalar environment beats YAML and repeated --set beats environment.
env = dict(os.environ, HINAGATA_MIGRATION_REVISION_EXECUTABLE="true")
run(status=4, env=env)
run(extra=["--set", "migration.revision_executable=true", "--set", "migration.revision_executable=false"], env=env)
# Schema/help/completion paths bypass even malformed declarations and file I/O.
write('revision_inputs: ["malformed-entry-sentinel"]')
for args in (["--describe-config-json"], ["db", "--help"], ["completions", "bash"]):
    result = subprocess.run(base + ["--config", str(overlay)] + args, capture_output=True, timeout=10)
    assert result.returncode == 0, result
