set shell := ["zsh", "-cu"]

core-test:
    cabal test hinagata-core-test --test-show-details=direct

postgres-test:
    cabal test hinagata-postgres-test --test-show-details=direct

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

check: check-conventions core-test postgres-test fmt-check
    cabal sdist hinagata-core
    cabal sdist hinagata-postgres
    nix flake check
