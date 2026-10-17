#!/usr/bin/env bash
# 65-label-nodes.sh - sourced by setup.sh (master only)
# What : kubelets may not set node-role.* labels themselves, so the master adds them. Safe to re-run.
export KUBECONFIG=/etc/kubernetes/admin.conf

label_workers() {
  local node
  for node in $(kubectl get nodes -l 'homelab/role=worker' -o name 2>/dev/null); do
    kubectl label "$node" node-role.kubernetes.io/worker= --overwrite >/dev/null
  done
}

label_workers
kubectl get nodes -L homelab/role,homelab/disk,homelab/storage || true
