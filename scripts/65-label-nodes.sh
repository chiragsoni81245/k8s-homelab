#!/usr/bin/env bash
# 65-label-nodes.sh - sourced by setup.sh (master only)
# What : (1) refresh THIS node's labels from what is detected right now (disk type, /DATA mounted), so a
#            re-run after an upgrade or a changed setup picks them up; undetectable labels are left alone.
#        (2) add node-role.kubernetes.io/worker to joined workers (kubelets may not set node-role labels).
# Safe to re-run. Workers cannot label themselves: for those use `kubectl label node <name> key=value`.
export KUBECONFIG=/etc/kubernetes/admin.conf

label_this_node() {
  local labels
  labels="$(node_labels master)"
  # shellcheck disable=SC2046  # intentional word splitting: one key=value per argument
  kubectl label node "$NODE_NAME" $(tr ',' ' ' <<<"$labels") --overwrite >/dev/null \
    && log "Labelled $NODE_NAME: $labels" || warn "Could not label $NODE_NAME"
}

label_workers() {
  local node
  for node in $(kubectl get nodes -l 'homelab/role=worker' -o name 2>/dev/null); do
    kubectl label "$node" node-role.kubernetes.io/worker= --overwrite >/dev/null
  done
}

label_this_node
label_workers
kubectl get nodes -L homelab/role,homelab/disk,homelab/storage || true
