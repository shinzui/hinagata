#!/usr/bin/env bash
set -euo pipefail

project="$(pwd)"
workspace="$(mktemp -d)"
cleanup() {
  if test -d "$workspace/pg/data"; then
    pg_ctl -D "$workspace/pg/data" -m immediate -w stop >/dev/null 2>&1 || true
  fi
  rm -rf "$workspace"
}
trap cleanup EXIT
mkdir -p "$workspace/tarballs" "$workspace/unpacked"

cabal sdist all --output-directory "$workspace/tarballs"
for archive in "$workspace"/tarballs/*.tar.gz; do
  tar -xzf "$archive" -C "$workspace/unpacked"
done

keiro_source=("$workspace"/unpacked/hinagata-keiro-example-*)
test "${#keiro_source[@]}" -eq 1
test -f "${keiro_source[0]}/hurl-workbench.dhall"
test -f "${keiro_source[0]}/seed/Main.hs"
for artifact in application.sql manifest.json verify.sh verify.sql; do
  test -f "${keiro_source[0]}/migration/$artifact"
done
core_source=("$workspace"/unpacked/hinagata-core-*)
test -f "${core_source[0]}/src/Hinagata/Hook/Revision.hs"
test -f "${keiro_source[0]}/service/Counter.hs"
test -f "${keiro_source[0]}/hurl/counter-seeded.hurl"
test -f "${keiro_source[0]}/fixtures/reference-seed/fixture.sql"
test -f "${keiro_source[0]}/fixtures/service-scenario/fixture.yaml"
test -f "${keiro_source[0]}/fixtures/service-scenario-alternate/fixture.yaml"
hurlfmt --check "${keiro_source[0]}"/hurl/*.hurl

cat > "$workspace/unpacked/cabal.project" <<'PROJECT'
packages: ./*/*.cabal
tests: True
benchmarks: True
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
# Consume only unpacked artifacts with the independently built migration binary.
# This cluster and all selected locations are inside the release-check workspace.
mkdir -p "$workspace/pg/socket"
initdb -D "$workspace/pg/data" --auth=trust --no-locale --encoding=UTF8 --no-instructions >/dev/null
port=$((20000 + ($$ % 30000)))
pg_ctl -D "$workspace/pg/data" -l "$workspace/pg/postgres.log" -o "-k '$workspace/pg/socket' -p $port -c listen_addresses=''" -w start >/dev/null
export PGHOST="$workspace/pg/socket" PGPORT="$port" PGUSER="$(id -un)" PGDATABASE=postgres
psql -v ON_ERROR_STOP=1 -qAtc 'CREATE ROLE hinagata_example_setup LOGIN; CREATE ROLE hinagata_example_app LOGIN;'
archive_migrate="$(cabal list-bin hinagata-keiro-migrate)"
export EXAMPLE_MIGRATION_MANIFEST="${keiro_source[0]}/migration/manifest.json"
export EXAMPLE_SCHEMA_MARKER="archive-marker"
export EXAMPLE_VERIFY_BINARY="$archive_migrate"
"$archive_migrate" up
psql -v ON_ERROR_STOP=1 -f "${keiro_source[0]}/fixtures/reference-seed/fixture.sql" >/dev/null
bash "${keiro_source[0]}/migration/verify.sh"
# Invalid manifest fields must fail without echoing their selected values/paths.
printf '%s\n' '{"id":"private-manifest-sentinel","sql":"../private-path-sentinel.sql"}' > "$workspace/invalid-manifest.json"
if EXAMPLE_MIGRATION_MANIFEST="$workspace/invalid-manifest.json" "$archive_migrate" up > "$workspace/invalid.out" 2> "$workspace/invalid.err"; then
  echo "invalid packaged manifest unexpectedly succeeded" >&2
  exit 1
fi
! rg -q 'private-manifest-sentinel|private-path-sentinel' "$workspace/invalid.out" "$workspace/invalid.err"
echo "isolated source distributions built, tested, documented, and passed archive CLI and declared migration/verification smoke"
