#!/usr/bin/env bash
# Resets the Argo CD "admin" password (e.g. after argocd-initial-admin-secret was deleted).
#   Empty prompt  -> Argo CD generates a new one: the admin password is cleared, argocd-server restarted, and the
#                    new value is read from the re-created argocd-initial-admin-secret (shown once).
#   Typed password -> its bcrypt hash is written to argocd-secret directly (no restart needed).
# Either way existing sessions are logged out. The password never touches git, disk or a command line.
# Usage: sudo tools/reset-argocd-password.sh        (ARGOCD_ADMIN_PASSWORD may be set in the environment)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
LOG_FILE=/dev/null

NAMESPACE=argocd

use_cluster_kubeconfig() {
  if [[ -z "${KUBECONFIG:-}" && -r /etc/kubernetes/admin.conf ]]; then export KUBECONFIG=/etc/kubernetes/admin.conf; fi
  kubectl -n "$NAMESPACE" get secret argocd-secret >/dev/null 2>&1 \
    || die "Cannot read $NAMESPACE/argocd-secret (run on the master, with sudo if needed)."
}

# bcrypt hash of $ARGOCD_ADMIN_PASSWORD: htpasswd if installed, else the argocd CLI inside the argocd-server pod
# (the password goes in over stdin, not as a kubectl argument).
bcrypt_hash() {
  if have htpasswd; then
    printf '%s\n' "$ARGOCD_ADMIN_PASSWORD" | htpasswd -niBC 10 "" | tr -d ':\n' | sed 's/^\$2y/$2a/'
  else
    printf '%s\n' "$ARGOCD_ADMIN_PASSWORD" | kubectl -n "$NAMESPACE" exec -i deploy/argocd-server -- \
      sh -c 'read -r p; argocd account bcrypt --password "$p"'
  fi
}

set_password() {
  local hash
  hash="$(bcrypt_hash)"
  [[ "$hash" == \$2* ]] || die "Could not hash the password."
  kubectl -n "$NAMESPACE" patch secret argocd-secret --type merge --patch-file <(
    printf '{"stringData":{"admin.password":"%s","admin.passwordMtime":"%s"}}' "$hash" "$(date -u +%FT%TZ)"
  ) >/dev/null
  log "Argo CD admin password set."
}

regenerate_password() {
  kubectl -n "$NAMESPACE" delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null
  kubectl -n "$NAMESPACE" patch secret argocd-secret --type merge \
    -p '{"data":{"admin.password":null,"admin.passwordMtime":null}}' >/dev/null
  kubectl -n "$NAMESPACE" rollout restart deployment argocd-server >/dev/null
  kubectl -n "$NAMESPACE" rollout status deployment argocd-server --timeout=300s >/dev/null
  retry 30 2 kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret >/dev/null \
    || die "argocd-initial-admin-secret was not re-created; check: kubectl -n $NAMESPACE logs deploy/argocd-server"
  echo "New Argo CD admin password (shown once, save it): $(
    kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" >&2
  log "Once saved, delete the copy: kubectl -n $NAMESPACE delete secret argocd-initial-admin-secret"
}

use_cluster_kubeconfig
confirm "Reset the Argo CD admin password (logs out current sessions)?" n || { log "Left as is."; exit 0; }
ARGOCD_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD:-}"
prompt_secret ARGOCD_ADMIN_PASSWORD "New admin password (hidden; empty = let Argo CD generate one)"
if [[ -n "$ARGOCD_ADMIN_PASSWORD" ]]; then set_password; else regenerate_password; fi
unset ARGOCD_ADMIN_PASSWORD
log "Log in at https://argocd.chiragsoni.org as admin."
