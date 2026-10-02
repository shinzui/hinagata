set shell := ["zsh", "-cu"]

core-test:
    cabal test hinagata-core-test --test-show-details=direct

check-conventions:
    python3 scripts/check_conventions.py

fmt-check:
    nix fmt -- --ci

check: check-conventions core-test fmt-check
    cabal sdist hinagata-core
    nix flake check
