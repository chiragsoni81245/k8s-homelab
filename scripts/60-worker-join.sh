#!/usr/bin/env bash
# 60-worker-join.sh - sourced by setup.sh (worker only)
# What : `kubeadm join` through the stable endpoint name; node labels are set at join time.
# Files: templates/kubernetes/kubeadm-join.yaml

ask_master_details() {
  prompt MASTER_IP "Master node IP" "${MASTER_IP:-}"
  is_ipv4 "$MASTER_IP" || die "Invalid master IP: $MASTER_IP"
  ask_default CONTROL_PLANE_ENDPOINT "Control-plane endpoint (must match the master's)"
  ensure_hosts_entry "$MASTER_IP" "$CONTROL_PLANE_ENDPOINT"
  config_set MASTER_IP "$MASTER_IP"
  (exec 3<>"/dev/tcp/$MASTER_IP/6443") 2>/dev/null || die "Cannot reach $MASTER_IP:6443 (master up? firewall?)"
}

ask_token_and_ca_hash() {
  prompt_secret JOIN_TOKEN "Join token (abcdef.0123456789abcdef)"
  [[ "$JOIN_TOKEN" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]] || die "Token format invalid."

  [[ -n "${CA_HASH:-}" ]] || prompt CA_HASH "CA cert hash (sha256:... from the master's join command; 'skip' = INSECURE)" "skip"
  if [[ "$CA_HASH" == skip ]]; then
    warn "Skipping CA verification: a man-in-the-middle could impersonate the master."
    confirm "Continue without CA verification?" n || die "Aborted."
    CA_VERIFY='unsafeSkipCAVerification: true'
  else
    [[ "$CA_HASH" == sha256:* ]] || CA_HASH="sha256:$CA_HASH"
    CA_VERIFY="caCertHashes: [$CA_HASH]"
  fi
}

node_labels() {
  local labels
  labels="homelab/role=worker,homelab/disk=$(disk_kind)"
  [[ "${DATA_MOUNTED:-no}" == yes ]] && labels+=",homelab/storage=media"
  echo "$labels"
}

run_kubeadm_join() {
  NODE_LABELS="$(node_labels)"
  export CONTROL_PLANE_ENDPOINT JOIN_TOKEN CA_VERIFY NODE_NAME NODE_IP NODE_LABELS
  install_rendered kubernetes/kubeadm-join.yaml /etc/kubernetes/kubeadm-join.yaml 600
  step "kubeadm join"
  kubeadm join --config /etc/kubernetes/kubeadm-join.yaml
  shred -u /etc/kubernetes/kubeadm-join.yaml 2>/dev/null || rm -f /etc/kubernetes/kubeadm-join.yaml   # contains the token
  unset JOIN_TOKEN
  log "Joined with labels: $NODE_LABELS"
  log "On the master, re-run 'sudo ./setup.sh' to add the node-role.kubernetes.io/worker label."
}

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  log "This node already joined a cluster - skipping kubeadm join."
else
  ask_master_details
  ask_token_and_ca_hash
  run_kubeadm_join
fi
