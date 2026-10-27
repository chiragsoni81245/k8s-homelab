#!/usr/bin/env bash
# Creates the Proton Pass personal access token Secret (proton-secrets-system/proton-pat) that the
# proton-secrets-operator logs in with. It is the single bootstrap secret: never stored in git or on disk.
# Create the PAT first (read-only/viewer, scoped to ONE dedicated vault, with an expiry date):
#   pass-cli login && pass-cli pat create ...   (see https://protonpass.github.io/pass-cli/)
# Also stores the PAT expiry (key expires-at, RFC3339) in the same Secret; the operator exports it for the expiry alert.
# Usage: tools/create-proton-pat-secret.sh   (PROTON_PASS_PERSONAL_ACCESS_TOKEN / PROTON_PASS_PAT_EXPIRES_AT may be set)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
LOG_FILE=/dev/null

NAMESPACE=proton-secrets-system
SECRET=proton-pat
DEPLOY=proton-secrets-operator

use_cluster_kubeconfig() {
  if [[ -z "${KUBECONFIG:-}" && -r /etc/kubernetes/admin.conf ]]; then export KUBECONFIG=/etc/kubernetes/admin.conf; fi
  kubectl get ns >/dev/null 2>&1 || die "Cannot reach the cluster (run on the master, with sudo if needed)."
}

use_cluster_kubeconfig

REPLACED=0
if kubectl -n "$NAMESPACE" get secret "$SECRET" >/dev/null 2>&1; then
  confirm "Secret $NAMESPACE/$SECRET already exists. Replace it (token rotation)?" n || { log "Left as is."; exit 0; }
  REPLACED=1
fi

PROTON_PASS_PERSONAL_ACCESS_TOKEN="${PROTON_PASS_PERSONAL_ACCESS_TOKEN:-}"
prompt_secret PROTON_PASS_PERSONAL_ACCESS_TOKEN "Proton Pass personal access token (hidden)"
[[ -n "$PROTON_PASS_PERSONAL_ACCESS_TOKEN" ]] || die "Empty token."

PROTON_PASS_PAT_EXPIRES_AT="${PROTON_PASS_PAT_EXPIRES_AT:-}"
if [[ -z "$PROTON_PASS_PAT_EXPIRES_AT" ]]; then
  read -r -p "PAT expiry, UTC (e.g. 2026-12-31 or 2026-12-31T23:59:59Z): " PROTON_PASS_PAT_EXPIRES_AT <"$(_tty)"
fi
# Accept a plain date; the operator needs RFC3339.
[[ "$PROTON_PASS_PAT_EXPIRES_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && PROTON_PASS_PAT_EXPIRES_AT+="T23:59:59Z"
[[ "$PROTON_PASS_PAT_EXPIRES_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || die "Expiry must look like 2026-12-31 or 2026-12-31T23:59:59Z."
date -d "$PROTON_PASS_PAT_EXPIRES_AT" >/dev/null 2>&1 || die "Not a valid date: $PROTON_PASS_PAT_EXPIRES_AT"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# from-file with process substitution: the token never appears in the process list
kubectl -n "$NAMESPACE" create secret generic "$SECRET" \
  --from-file=token=<(printf '%s' "$PROTON_PASS_PERSONAL_ACCESS_TOKEN") \
  --from-literal=expires-at="$PROTON_PASS_PAT_EXPIRES_AT" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset PROTON_PASS_PERSONAL_ACCESS_TOKEN

log "Secret $NAMESPACE/$SECRET is in place."
if (( REPLACED )); then
  # The token file is re-read at every login (every ~100 min); restart to pick it up immediately.
  kubectl -n "$NAMESPACE" rollout restart "deployment/$DEPLOY" >/dev/null 2>&1 || true
fi
log "PAT expiry recorded: $PROTON_PASS_PAT_EXPIRES_AT (alert fires 14 days before)."
