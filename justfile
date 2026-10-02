set shell := ["zsh", "-cu"]

core-test:
    cabal test hinagata-core-test --test-show-details=direct

postgres-test:
    cabal test hinagata-postgres-test --test-show-details=direct

test-cli:
    cabal build hinagata-cli
    bash scripts/test-cli.sh

test-cli-postgres:
    cabal build hinagata-cli
    bash scripts/test-postgres.sh --cli

example-workbench:
    cabal build hinagata-cli hinagata-workbench-example
    hurlfmt --check examples/workbench/hurl/health.hurl examples/workbench/hurl/members.hurl examples/workbench/hurl/intentional-failure.hurl examples/workbench/hurl/slow.hurl
    bash scripts/test-postgres.sh --example

example-keiro:
    cabal build hinagata-cli hinagata-keiro-example
    hurlfmt --check examples/keiro-service/hurl/health.hurl examples/keiro-service/hurl/references.hurl examples/keiro-service/hurl/references-alternate.hurl examples/keiro-service/hurl/counter-write.hurl examples/keiro-service/hurl/generated-id.hurl examples/keiro-service/hurl/hold.hurl
    bash scripts/test-postgres.sh --keiro-example

test-postgres:
    bash scripts/test-postgres.sh

test-postgres-tcp:
    bash scripts/test-postgres.sh --tcp

test-postgres-bulk:
    bash scripts/test-postgres.sh --bulk-baseline

bench-postgres:
    bash scripts/test-postgres.sh --bench

bench-fixtures:
    cabal build hinagata-cli hinagata-postgres-direct-load hinagata-postgres-concurrent-leases
    bash scripts/test-postgres.sh --bench-fixtures

release-check:
    bash scripts/release-check.sh

check-conventions:
    python3 scripts/check_conventions.py

fmt-check:
    nix fmt -- --ci

check: check-conventions core-test postgres-test test-cli fmt-check
    cabal sdist hinagata-core
    cabal sdist hinagata-postgres
    cabal sdist hinagata-cli
    cabal sdist hinagata-workbench-example
    cabal sdist hinagata-keiro-example
    nix flake check
