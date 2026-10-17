#!/usr/bin/env bash
# Turn a bare Ubuntu Server into a Kubernetes master or worker. Idempotent: safe to re-run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"

usage() { cat <<USAGE
Usage: sudo ./setup.sh [--role master|worker] [--yes] [--non-interactive]
Env overrides: ROLE MASTER_IP NODE_IP NODE_NAME CONTROL_PLANE_ENDPOINT JOIN_TOKEN CA_HASH
               NETBIRD_SETUP_KEY GITOPS_REPO_URL GITOPS_REVISION ...  (see config.env.example)
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --yes|-y) ASSUME_YES=1; shift;;
    --non-interactive) NONINTERACTIVE=1; shift;;
    -h|--help) usage; exit 0;;
    *) usage; exit 1;;
  esac
done

require_root
touch "$LOG_FILE" 2>/dev/null || true
log "k8s-homelab setup (repo: $ROOT)"

run() { # run <script> : sourced so it shares vars/functions
  step "$1"
  # shellcheck disable=SC1090
  source "$ROOT/scripts/$1"
}

run 00-preflight.sh

if [[ -z "${ROLE:-}" ]]; then
  if [[ -f /etc/kubernetes/admin.conf ]]; then ROLE=master
  elif [[ -f /etc/kubernetes/kubelet.conf ]]; then ROLE=worker
  else prompt ROLE "Is this node a k8s 'master' or 'worker'?"; fi
fi
ROLE="${ROLE,,}"
[[ "$ROLE" == master || "$ROLE" == worker ]] || die "Role must be 'master' or 'worker' (got '$ROLE')."
config_set ROLE "$ROLE"
log "Role: $ROLE"

run 05-identity.sh
run 10-server-mode.sh
run 15-firewall.sh
run 20-system-prep.sh
run 30-container-runtime.sh
run 40-kube-packages.sh

if [[ "$ROLE" == master ]]; then
  run 50-master-init.sh
  run 55-master-bootstrap.sh
  run 65-label-nodes.sh
else
  run 35-data-mount.sh
  run 60-worker-join.sh
fi

run 70-netbird.sh
step "Done"
log "Role '$ROLE' is set up. Logs: $LOG_FILE"
