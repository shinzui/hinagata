#!/usr/bin/env python3
"""Small mechanical part of the Haskell conventions gate.

Record/optic use and transitive orphan exposure still need source review.
"""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
errors: list[str] = []

for cabal_file in sorted(ROOT.glob("*/*.cabal")):
    content = cabal_file.read_text()
    if not re.search(r"(?m)^common common\s*$", content):
        errors.append(f"{cabal_file}: missing common common stanza")
    for component in re.finditer(r"(?m)^(library|executable|test-suite|benchmark)(?:[ \t]+[^\n]+)?\n((?:[ \t]+[^\n]*\n|\n)*)", content):
        kind, body = component.groups()
        if not re.search(r"(?m)^\s+import:\s*common\s*$", body):
            errors.append(f"{cabal_file}: {kind} lacks import: common")

for source in sorted(ROOT.glob("*/**/*.hs")):
    if "dist-newstyle" in source.parts:
        continue
    content = source.read_text()
    if re.search(r"(?m)^import\s+qualified\s+", content):
        errors.append(f"{source}: use postpositive qualified imports")
    if source.name != "Prelude.hs" and "PackageImports" in content:
        errors.append(f"{source}: PackageImports belongs only in the prelude")
    if source.parts[-2:] == ("Hinagata", "Prelude.hs") and "Data.Generics.Labels" in content:
        errors.append(f"{source}: generic-lens orphan must not enter the prelude")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)

print("Conventions scan passed; record and import-closure review remains manual.")
