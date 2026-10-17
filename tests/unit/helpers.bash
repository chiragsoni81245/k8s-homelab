# Shared setup for all unit tests. Everything runs inside a temp dir; /etc is never touched.
ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup_env() {
  TMP="$(mktemp -d)"
  export LOG_FILE="$TMP/test.log"
  export CONFIG_FILE="$TMP/config.env"
  export HOSTS_FILE="$TMP/hosts"
  export NONINTERACTIVE=1
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/config.sh"
}

teardown_env() { rm -rf "$TMP"; }
