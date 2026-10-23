#!/usr/bin/env bash
# Creates the Grafana admin login Secret (monitoring/grafana-admin) that the victoria-metrics app reads.
# The password is never stored in git or on disk. Leave the prompt empty to generate a strong one (shown once).
# Usage: tools/create-grafana-secret.sh        (GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD may be set in the environment)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
LOG_FILE=/dev/null

NAMESPACE=monitoring
SECRET=grafana-admin

use_cluster_kubeconfig() {
  if [[ -z "${KUBECONFIG:-}" && -r /etc/kubernetes/admin.conf ]]; then export KUBECONFIG=/etc/kubernetes/admin.conf; fi
  kubectl get ns >/dev/null 2>&1 || die "Cannot reach the cluster (run on the master, with sudo if needed)."
}

secret_exists() { kubectl -n "$NAMESPACE" get secret "$SECRET" >/dev/null 2>&1; }

# Sets GRAFANA_ADMIN_PASSWORD (prompted, from the environment, or generated) and GENERATED=1 if we made it.
choose_password() {
  GENERATED=0
  GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"
  if [[ -z "$GRAFANA_ADMIN_PASSWORD" ]]; then
    prompt_secret GRAFANA_ADMIN_PASSWORD "Grafana admin password (hidden; empty = generate one)"
  fi
  if [[ -z "$GRAFANA_ADMIN_PASSWORD" ]]; then
    GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 24)"
    GENERATED=1
  fi
}

apply_secret() {
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # from-file with process substitution: the values never appear in the process list
  kubectl -n "$NAMESPACE" create secret generic "$SECRET" \
    --from-file=admin-user=<(printf '%s' "$GRAFANA_ADMIN_USER") \
    --from-file=admin-password=<(printf '%s' "$GRAFANA_ADMIN_PASSWORD") \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

restart_grafana() {  # Grafana only reads the Secret at start
  kubectl -n "$NAMESPACE" get deploy -l app.kubernetes.io/name=grafana -o name 2>/dev/null \
    | xargs -r -n1 kubectl -n "$NAMESPACE" rollout restart >/dev/null
}

use_cluster_kubeconfig
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"

if secret_exists; then
  confirm "Secret $NAMESPACE/$SECRET already exists. Replace it (this changes the Grafana login)?" n || { log "Left as is."; exit 0; }
  REPLACED=1
else
  REPLACED=0
fi

choose_password
apply_secret
(( REPLACED )) && restart_grafana

log "Secret $NAMESPACE/$SECRET is in place (user: $GRAFANA_ADMIN_USER)."
if (( GENERATED )); then
  echo "Generated Grafana password (shown once, save it): $GRAFANA_ADMIN_PASSWORD" >&2
fi
unset GRAFANA_ADMIN_PASSWORD
log "Grafana picks it up on its next start: kubectl -n $NAMESPACE get pods | grep grafana"
