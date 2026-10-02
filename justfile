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

test-postgres:
    bash scripts/test-postgres.sh

test-postgres-tcp:
    bash scripts/test-postgres.sh --tcp

test-postgres-bulk:
    bash scripts/test-postgres.sh --bulk-baseline

bench-postgres:
    bash scripts/test-postgres.sh --bench

check-conventions:
    python3 scripts/check_conventions.py

fmt-check:
    nix fmt -- --ci

check: check-conventions core-test postgres-test test-cli fmt-check
    cabal sdist hinagata-core
    cabal sdist hinagata-postgres
    cabal sdist hinagata-cli
    nix flake check
