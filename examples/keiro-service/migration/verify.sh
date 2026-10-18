#!/usr/bin/env bash
set -euo pipefail
"${EXAMPLE_VERIFY_BINARY:?}" verify
psql -v ON_ERROR_STOP=1 -f "$(dirname "$0")/verify.sql"
