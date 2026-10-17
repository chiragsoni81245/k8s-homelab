#!/usr/bin/env bash
# 00-preflight.sh - sourced by setup.sh (both roles)
# What : sanity-check the machine and confirm which NIC/IP this node uses.
# Sets : ARCH, DEFAULT_IF, NODE_IP   (NODE_IP is also saved to config.env)

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

# Pick the wired NIC and confirm the (DHCP-reserved) IP the router gives this node.
detect_network() {
  DEFAULT_IF="$(ip -4 route show default | awk '{print $5; exit}')"
  [[ -n "$DEFAULT_IF" ]] || die "No default route. Connect Ethernet first."
  [[ ! -d "/sys/class/net/$DEFAULT_IF/wireless" ]] \
    || die "Default route is on Wi-Fi ($DEFAULT_IF). Use Ethernet; Wi-Fi is disabled by this script."

  local detected_ip
  detected_ip="$(ip -4 -o addr show dev "$DEFAULT_IF" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  prompt NODE_IP "This node's LAN IP (the reserved address on $DEFAULT_IF)" "$detected_ip"
  is_ipv4 "$NODE_IP" || die "Invalid IP: $NODE_IP"
  ip -4 -o addr show | grep -qw "$NODE_IP" || die "$NODE_IP is not assigned to any local interface."
  export NODE_IP DEFAULT_IF
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
log "Preflight OK (NIC $DEFAULT_IF, IP $NODE_IP)"
