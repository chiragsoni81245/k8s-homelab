#!/usr/bin/env bash
# Run everything that needs no cluster:  tests/run.sh
# (tests/smoke-test.sh is different: it needs a running cluster.)
set -euo pipefail
cd "$(dirname "$0")/.."
tests/lint.sh
command -v bats >/dev/null || { echo "bats not installed (apt install bats)"; exit 1; }
bats tests/unit
