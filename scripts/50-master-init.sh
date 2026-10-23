#!/usr/bin/env bash
# 50-master-init.sh - sourced by setup.sh (master only)
# What : `kubeadm init` using a stable DNS endpoint; master stays schedulable (no taint).
# Files: templates/kubernetes/{kubeadm-init.yaml,apiserver-encryption.yaml,encryption-config.yaml}
# Sets : MASTER_IP, CONTROL_PLANE_ENDPOINT, KUBECONFIG
export KUBECONFIG=/etc/kubernetes/admin.conf

choose_endpoint() {
  ask_default CONTROL_PLANE_ENDPOINT "Control-plane endpoint (DNS name used by every kubeconfig and join)"
  is_host_or_ip "$CONTROL_PLANE_ENDPOINT" || die "Invalid endpoint: $CONTROL_PLANE_ENDPOINT"
  MASTER_IP="$NODE_IP"
  config_set MASTER_IP "$MASTER_IP"
  ensure_hosts_entry "$MASTER_IP" "$CONTROL_PLANE_ENDPOINT"
  getent hosts "$CONTROL_PLANE_ENDPOINT" >/dev/null || die "Cannot resolve $CONTROL_PLANE_ENDPOINT"
  log "$CONTROL_PLANE_ENDPOINT -> $MASTER_IP (via /etc/hosts). Add a DNS/router record so other devices resolve it too."
}

# Optional: encrypt Secrets in etcd. Fills APISERVER_EXTRA for the kubeadm template.
prepare_secrets_encryption() {
  APISERVER_EXTRA=""
  ask_default ENABLE_SECRETS_ENCRYPTION "Encrypt Secrets at rest in etcd? (yes/no)"
  [[ "$ENABLE_SECRETS_ENCRYPTION" == yes ]] || return 0
  install -d -m 700 /etc/kubernetes/enc
  ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"; export ENCRYPTION_KEY
  [[ -s /etc/kubernetes/enc/encryption-config.yaml ]] \
    || install_rendered kubernetes/encryption-config.yaml /etc/kubernetes/enc/encryption-config.yaml 600
  unset ENCRYPTION_KEY
  APISERVER_EXTRA="$(cat "$REPO_ROOT/templates/kubernetes/apiserver-encryption.yaml")"
}

run_kubeadm_init() {
  NODE_LABELS="$(node_labels master)"
  export MASTER_IP NODE_NAME NODE_LABELS K8S_VERSION CONTROL_PLANE_ENDPOINT POD_CIDR SERVICE_CIDR APISERVER_EXTRA
  install_rendered kubernetes/kubeadm-init.yaml /etc/kubernetes/kubeadm-config.yaml 600
  step "kubeadm init"
  kubeadm config images pull --config /etc/kubernetes/kubeadm-config.yaml
  kubeadm init --config /etc/kubernetes/kubeadm-config.yaml
}

# kubeconfig for root and for the user who ran sudo
install_kubeconfig() {
  install -d -m 700 /root/.kube
  install -m 600 /etc/kubernetes/admin.conf /root/.kube/config
  [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || return 0
  local home; home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  install -d -m 700 -o "$SUDO_USER" -g "$SUDO_USER" "$home/.kube"
  install -m 600 -o "$SUDO_USER" -g "$SUDO_USER" /etc/kubernetes/admin.conf "$home/.kube/config"
}

choose_endpoint
if [[ -f /etc/kubernetes/admin.conf ]]; then
  log "Cluster already initialized on this node - skipping kubeadm init."
else
  prepare_secrets_encryption
  run_kubeadm_init
fi
install_kubeconfig
retry 30 5 kubectl get --raw /readyz >/dev/null || die "API server not ready"
kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true   # keep schedulable
log "Control plane ready. The node stays NotReady until Cilium is installed (next step)."
