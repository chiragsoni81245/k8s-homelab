#!/usr/bin/env bash
# 15-firewall.sh - sourced by setup.sh (both roles), OPTIONAL
# What : ufw default-deny inbound, allowing the LAN, NetBird (wt0) and Cilium interfaces.
# Off by default: Kubernetes/Cilium plus a host firewall can be fiddly. Enable: ENABLE_FIREWALL=yes

firewall_wanted() {
  [[ "$ENABLE_FIREWALL" == yes ]] && return 0
  [[ "${NONINTERACTIVE:-0}" == 1 ]] && return 1
  confirm "Enable ufw host firewall (deny inbound except LAN + NetBird + Cilium)?" n
}

lan_network() {  # subnet of the NIC that owns NODE_IP, e.g. 192.168.0.0/24
  local cidr; cidr="$(ip -4 -o addr show dev "$NODE_IF" | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $4; exit}')"
  python3 -c "import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network)" "$cidr"
}

configure_ufw() {
  local lan; lan="$(lan_network)"
  apt_install ufw
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw default allow routed                      # pod traffic is forwarded
  ufw allow from "$lan"      comment 'LAN'
  ufw allow from "$lan" to any port 22 proto tcp comment 'SSH from LAN'
  ufw allow in on wt0        comment 'NetBird'
  ufw allow in on cilium_host   comment 'Cilium'
  ufw allow in on cilium_vxlan  comment 'Cilium tunnel'
  ufw allow in on lxc+          comment 'Cilium pods'
  ufw --force enable
  config_set ENABLE_FIREWALL yes
  log "ufw enabled (allowed: $lan, wt0, cilium interfaces)"
}

if firewall_wanted; then configure_ufw; else log "Firewall step skipped (ENABLE_FIREWALL=no)"; fi
