#!/usr/bin/env bash
# Static checks - no root, no network, no system changes.
#   Runs the shell linter on every script, bash -n, and a YAML parse of gitops/
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0

shell_files=(setup.sh install.sh update.sh lib/*.sh scripts/*.sh tools/*.sh tests/*.sh)

echo "== bash -n =="
for f in "${shell_files[@]}"; do bash -n "$f" || { echo "SYNTAX ERROR: $f"; fail=1; }; done

echo "== shellcheck =="
if command -v shellcheck >/dev/null; then
  shellcheck -x -S warning "${shell_files[@]}" || fail=1
else
  echo "shellcheck not installed (apt install shellcheck) - skipped"; fail=1
fi

echo "== YAML =="
python3 - <<'PY' || fail=1
import glob, sys, yaml
bad = 0
for f in sorted(glob.glob("gitops/**/*.yaml", recursive=True)):
    try:
        list(yaml.safe_load_all(open(f)))
    except yaml.YAMLError as e:
        print(f"INVALID YAML: {f}: {e}"); bad = 1
sys.exit(bad)
PY

echo "== YAML style (block style only; empty {} and [] are fine) =="
if grep -rnE "^[^#]*[:-] *[\{\[]" gitops templates .github --include=*.yaml --include=*.yml \
     | grep -vE "(\{\}|\[\])[[:space:]]*(#.*)?$|'\{|\$\{"; then
  echo "Flow-style YAML found above: write it as block style."; fail=1
fi

[[ $fail == 0 ]] && echo "LINT OK" || echo "LINT FAILED"
exit $fail
