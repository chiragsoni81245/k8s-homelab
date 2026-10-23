#!/usr/bin/env bash
# 05-identity.sh - sourced by setup.sh (both roles)
# What : give the node a unique lowercase hostname (it becomes the Kubernetes node name).
# Sets : NODE_NAME (saved to config.env)

choose_node_name() {
  local current default=""
  current="$(hostnamectl --static 2>/dev/null || hostname)"; current="${current,,}"
  [[ "$current" == ubuntu || "$current" == localhost ]] || default="$current"

  if [[ -z "${NODE_NAME:-}" ]]; then
    NODE_NAME="$default"
    [[ -n "$NODE_NAME" ]] || prompt NODE_NAME "Hostname for this node (unique, lowercase; 'ubuntu'/'localhost' are too generic)"
  fi
  NODE_NAME="${NODE_NAME,,}"
  [[ "$NODE_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "Invalid hostname '$NODE_NAME'."
}

apply_hostname() {
  local current; current="$(hostnamectl --static 2>/dev/null || hostname)"
  if [[ "${current,,}" != "$NODE_NAME" ]]; then
    [[ ! -f /etc/kubernetes/kubelet.conf ]] || die "Node already joined as '$current'; refusing to rename."
    hostnamectl set-hostname "$NODE_NAME"
    log "Hostname set to $NODE_NAME"
  fi
  grep -qE "^127\.0\.1\.1[[:space:]]+$NODE_NAME" /etc/hosts || {
    sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
    echo "127.0.1.1 $NODE_NAME" >>/etc/hosts
  }
}

choose_node_name
apply_hostname
export NODE_NAME
config_set NODE_NAME "$NODE_NAME"
