#!/usr/bin/env bash
# 70-netbird.sh - sourced by setup.sh (both roles), OPTIONAL
# What : host-level NetBird agent (keeps working even when Kubernetes is down).
#        The setup key is read hidden, passed straight to `netbird up`, never written to disk.

netbird_connected() { have netbird && netbird status 2>/dev/null | grep -q 'Management: Connected'; }

netbird_wanted() {
  [[ -n "${NETBIRD_SETUP_KEY:-}" ]] && return 0
  [[ "${NONINTERACTIVE:-0}" == 1 ]] && return 1
  confirm "Install NetBird VPN agent on this node?" y || return 1
  prompt_secret NETBIRD_SETUP_KEY "NetBird setup key (hidden; empty = install only)"
}

install_netbird() {
  add_apt_repo netbird https://pkgs.netbird.io/debian/public.key "https://pkgs.netbird.io/debian stable main"
  install_pinned netbird "$NETBIRD_VERSION"
}

connect_netbird() {
  if [[ -z "${NETBIRD_SETUP_KEY:-}" ]]; then
    log "NetBird installed. Join later with: netbird up --setup-key <key>"; return 0
  fi
  local args=(up --setup-key "$NETBIRD_SETUP_KEY" --hostname "$NODE_NAME")
  [[ -n "${NETBIRD_MANAGEMENT_URL:-}" ]] && args+=(--management-url "$NETBIRD_MANAGEMENT_URL")
  netbird "${args[@]}"
  unset NETBIRD_SETUP_KEY
  log "NetBird connected. In the NetBird console make this peer a routing peer for your LAN/LB range and set ACLs."
}

if netbird_connected; then
  log "NetBird already connected."
elif netbird_wanted; then
  install_netbird
  connect_netbird
else
  log "NetBird skipped."
fi
