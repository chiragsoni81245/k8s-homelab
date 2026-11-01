#!/usr/bin/env bash
# Creates the Proton Pass personal access token Secret (proton-secrets-system/proton-pat) that the
# proton-secrets-operator logs in with. It is the single bootstrap secret: never stored in git or on disk.
# Create the PAT first (read-only/viewer, scoped to ONE dedicated vault):
#   pass-cli login && pass-cli pat create ...   (see https://protonpass.github.io/pass-cli/)
# Usage: tools/create-proton-pat-secret.sh   (PROTON_PASS_PERSONAL_ACCESS_TOKEN may be set)
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

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# from-file with process substitution: the token never appears in the process list
kubectl -n "$NAMESPACE" create secret generic "$SECRET" \
  --from-file=token=<(printf '%s' "$PROTON_PASS_PERSONAL_ACCESS_TOKEN") \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset PROTON_PASS_PERSONAL_ACCESS_TOKEN

log "Secret $NAMESPACE/$SECRET is in place."
if (( REPLACED )); then
  # The token file is re-read at every login (every ~100 min); restart to pick it up immediately.
  kubectl -n "$NAMESPACE" rollout restart "deployment/$DEPLOY" >/dev/null 2>&1 || true
fi
