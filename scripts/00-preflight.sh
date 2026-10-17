#!/usr/bin/env bash
# 00-preflight.sh - sourced by setup.sh (both roles)
# What : sanity-check the machine and confirm which NIC/IP this node uses.
# Sets : ARCH, DEFAULT_IF (default route NIC), NODE_IP, NODE_IF (NIC that owns NODE_IP)   (NODE_IP is also saved to config.env)

# shellcheck source=lib/network.sh
source "$REPO_ROOT/lib/network.sh"

install_base_tools() {
  have envsubst || apt_install gettext-base      # used to render templates/
  have jq || apt_install jq
}

check_os() {
  . /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || warn "Tested on Ubuntu Server; detected ${PRETTY_NAME:-unknown}."
  detect_arch
}

check_resources() {
  local mem_mb; mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  (( $(nproc) >= 2 )) || die "kubeadm needs >= 2 CPUs (found $(nproc))."
  (( mem_mb >= 1700 )) || die "kubeadm needs >= ~2GB RAM (found ${mem_mb}MB)."
  log "CPU: $(nproc), RAM: ${mem_mb}MB, arch: $ARCH, disk: $(disk_kind)"
}

# Pick the NIC and confirm the (DHCP-reserved) IP this node uses.
detect_network() {
  DEFAULT_IF="$(ip -4 route show default | awk '{print $5; exit}')"
  [[ -n "$DEFAULT_IF" ]] || die "No default route. Connect the network first."

  if [[ -z "${NODE_IP:-}" ]]; then
    choose_nic
    prompt NODE_IP "This node's IP on $NODE_IF_CHOICE" "$NODE_IP_DEFAULT"
  fi
  is_ipv4 "$NODE_IP" || die "Invalid IP: $NODE_IP"
  ip -4 -o addr show | grep -qw "$NODE_IP" || die "$NODE_IP is not assigned to any local interface."

  # the NIC that actually owns NODE_IP (may differ from the default-route NIC, e.g. NAT + Host-Only)
  NODE_IF="$(ip -4 -o addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')"
  if [[ -d "/sys/class/net/$NODE_IF/wireless" ]] && wireless_should_be_disabled; then
    die "$NODE_IF is Wi-Fi but Wi-Fi gets disabled. Use Ethernet, or set DISABLE_WIRELESS=no."
  fi
  export NODE_IP DEFAULT_IF NODE_IF
  config_set NODE_IP "$NODE_IP"
}

check_internet() {
  curl -fsS --max-time 15 -o /dev/null https://pkgs.k8s.io/ || die "No internet access to pkgs.k8s.io."
}

install_base_tools
check_os
check_resources
detect_network
check_internet
log "Preflight OK (node IP $NODE_IP on $NODE_IF; default route via $DEFAULT_IF)"
