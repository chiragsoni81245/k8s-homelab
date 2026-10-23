#!/usr/bin/env bash
# Creates or updates a Samba login: sets ACCOUNT_<user> in the Secret samba/samba-users WITHOUT touching the other
# users' keys, then restarts Samba (a changed Secret alone does not restart the pod).
# The password is never stored in git or on disk and never appears in the process list.
#
# Usage: sudo tools/create-samba-user.sh            (SAMBA_USER / SAMBA_PASSWORD may be set in the environment)
# Users, groups and shares are declared in gitops/apps/workloads/samba/manifests/configmap-samba-config.yaml.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
LOG_FILE=/dev/null

NAMESPACE=samba
SECRET=samba-users
DEPLOYMENT=samba
MANIFESTS="$ROOT/gitops/apps/workloads/samba/manifests"
CONFIGMAP="$MANIFESTS/configmap-samba-config.yaml"
SERVICE="$MANIFESTS/service-samba.yaml"

use_cluster_kubeconfig() {
  if [[ -z "${KUBECONFIG:-}" && -r /etc/kubernetes/admin.conf ]]; then export KUBECONFIG=/etc/kubernetes/admin.conf; fi
  kubectl get ns >/dev/null 2>&1 || die "Cannot reach the cluster (run on the master, with sudo if needed)."
}

valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; }    # lowercase, as the Samba image expects

# Users already declared in the ConfigMap (UID_<name> keys), one per line.
configured_users() { grep -oE '^[[:space:]]+UID_[a-z0-9_-]+' "$CONFIGMAP" 2>/dev/null | sed 's/.*UID_//'; }

# Everything is detected, nothing assumed: the first user declared in the ConfigMap, else the user who ran sudo.
default_user() {
  local first; first="$(configured_users | head -n1)"
  if [[ -n "$first" ]]; then echo "$first"
  elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then echo "${SUDO_USER,,}"
  fi
}

# The LAN address Samba is published on, read from the Service manifest (empty if not found).
samba_address() { grep -oE 'lbipam.cilium.io/ips:[[:space:]]*[0-9.]+' "$SERVICE" 2>/dev/null | awk '{print $2}'; }

choose_user() {
  local default; default="$(default_user)"
  SAMBA_USER="${SAMBA_USER:-}"
  if [[ -z "$SAMBA_USER" ]]; then
    prompt SAMBA_USER "Samba user name (lowercase)" "$default"
  fi
  SAMBA_USER="${SAMBA_USER,,}"
  valid_username "$SAMBA_USER" || die "Invalid user name '$SAMBA_USER' (lowercase letters, digits, _ and -)."
}

# Sets SAMBA_PASSWORD (environment, prompted twice, or generated) and GENERATED=1 if we made it.
choose_password() {
  local again; GENERATED=0
  SAMBA_PASSWORD="${SAMBA_PASSWORD:-}"
  if [[ -z "$SAMBA_PASSWORD" && "${NONINTERACTIVE:-0}" != 1 ]]; then
    prompt_secret SAMBA_PASSWORD "Password for $SAMBA_USER (hidden; empty = generate one)"
    if [[ -n "$SAMBA_PASSWORD" ]]; then
      prompt_secret again "Repeat the password"
      [[ "$SAMBA_PASSWORD" == "$again" ]] || die "Passwords do not match."
    fi
  fi
  if [[ -z "$SAMBA_PASSWORD" ]]; then
    SAMBA_PASSWORD="$(openssl rand -base64 18)"
    GENERATED=1
  fi
}

secret_exists() { kubectl -n "$NAMESPACE" get secret "$SECRET" >/dev/null 2>&1; }

# Merge ONE key into the Secret, leaving every other user's key alone. Values travel via stdin / process
# substitution, never through the command line.
store_password() {
  local key="ACCOUNT_$SAMBA_USER"
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if secret_exists; then
    KEY="$key" PW="$SAMBA_PASSWORD" python3 -c \
      'import json, os; print(json.dumps({"stringData": {os.environ["KEY"]: os.environ["PW"]}}))' \
      | kubectl -n "$NAMESPACE" patch secret "$SECRET" --type merge --patch-file /dev/stdin >/dev/null
  else
    kubectl -n "$NAMESPACE" create secret generic "$SECRET" --from-file="$key"=<(printf '%s' "$SAMBA_PASSWORD") >/dev/null
  fi
}

restart_samba() {   # the image reads accounts at start only
  if kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" rollout restart "deployment/$DEPLOYMENT" >/dev/null
    log "Restarted $DEPLOYMENT so the new login takes effect."
  else
    log "Samba is not deployed yet; the login is picked up when Argo creates the pod."
  fi
}

# Tell the user what else, if anything, they still have to do in git.
explain_next_steps() {
  local addr; addr="$(samba_address)"
  if ! configured_users | grep -qx "$SAMBA_USER"; then
    warn "'$SAMBA_USER' has no UID_$SAMBA_USER entry in configmap-samba-config.yaml (it gets an automatic uid)."
  fi
  if ! grep -qE "(valid users|write list)[^;]*\\b$SAMBA_USER\\b" "$CONFIGMAP" 2>/dev/null; then
    warn "'$SAMBA_USER' is not in any share's 'valid users' yet: add it (or a group via GROUPS_$SAMBA_USER) in the ConfigMap, bump homelab/config-revision in deployment-samba.yaml, push."
  fi
  if [[ -n "$addr" ]]; then log "Connect with: smb://$addr/<share>   (user: $SAMBA_USER)"; fi
}

main() {
  use_cluster_kubeconfig
  choose_user
  if secret_exists && kubectl -n "$NAMESPACE" get secret "$SECRET" -o json | grep -q "\"ACCOUNT_$SAMBA_USER\""; then
    confirm "ACCOUNT_$SAMBA_USER already exists. Replace its password?" n || { log "Left as is."; exit 0; }
  fi
  choose_password
  store_password
  log "Secret $NAMESPACE/$SECRET now has a password for '$SAMBA_USER' (other users untouched)."
  if (( GENERATED )); then echo "Generated password for $SAMBA_USER (shown once, save it): $SAMBA_PASSWORD" >&2; fi
  unset SAMBA_PASSWORD
  restart_samba
  explain_next_steps
}

# `source`-able for the unit tests; runs only when executed directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
