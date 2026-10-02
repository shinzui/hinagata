#!/usr/bin/env bash
set -euo pipefail

project="$(pwd)"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT
mkdir -p "$workspace/tarballs" "$workspace/unpacked"

cabal sdist all --output-directory "$workspace/tarballs"
for archive in "$workspace"/tarballs/*.tar.gz; do
  tar -xzf "$archive" -C "$workspace/unpacked"
done

cat > "$workspace/unpacked/cabal.project" <<'PROJECT'
packages: ./*/*.cabal
tests: True
benchmarks: False
write-ghc-environment-files: never
PROJECT

cd "$workspace/unpacked"
cabal build all
cabal test all --test-show-details=direct
cabal haddock all

cli="$(cabal list-bin hinagata)"
"$cli" --help > "$workspace/help.txt"
"$cli" --version > "$workspace/version.txt"
rg -q '^hinagata [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ \(revision unavailable\)$' "$workspace/version.txt"
echo "isolated source distributions built, tested, documented, and passed archive CLI smoke"
