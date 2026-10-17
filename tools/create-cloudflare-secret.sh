#!/usr/bin/env bash
# Creates the Cloudflare API token Secret that cert-manager uses for DNS-01 (never stored in git or on disk).
# Token permissions (Cloudflare dashboard -> My Profile -> API Tokens -> Create Token):
#   Zone / DNS / Edit   and   Zone / Zone / Read      for the zone chiragsoni.org only.
# Usage: tools/create-cloudflare-secret.sh      (CLOUDFLARE_API_TOKEN may be set in the environment)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
LOG_FILE=/dev/null

if [[ -z "${KUBECONFIG:-}" && -r /etc/kubernetes/admin.conf ]]; then export KUBECONFIG=/etc/kubernetes/admin.conf; fi
kubectl get ns >/dev/null 2>&1 || die "Cannot reach the cluster (run on the master, with sudo if needed)."

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
prompt_secret CLOUDFLARE_API_TOKEN "Cloudflare API token (input hidden)"
[[ -n "$CLOUDFLARE_API_TOKEN" ]] || die "Empty token."

# Optional sanity check against Cloudflare itself (the only place the token is sent). Header read from a pipe, not argv.
if confirm "Verify the token with Cloudflare first?" y; then
  status="$(curl -fsS https://api.cloudflare.com/client/v4/user/tokens/verify \
    -H @<(printf 'Authorization: Bearer %s' "$CLOUDFLARE_API_TOKEN") | jq -r '.result.status // "invalid"')" || status=invalid
  [[ "$status" == active ]] || die "Cloudflare says the token is '$status'."
  log "Token is active."
fi

kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-file=api-token=<(printf '%s' "$CLOUDFLARE_API_TOKEN") --dry-run=client -o yaml | kubectl apply -f -
unset CLOUDFLARE_API_TOKEN
log "Secret cert-manager/cloudflare-api-token is in place. Watch: kubectl -n envoy-gateway-system get certificate"
