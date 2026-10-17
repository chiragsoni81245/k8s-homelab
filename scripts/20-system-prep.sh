#!/usr/bin/env bash
# 20-system-prep.sh - sourced by setup.sh (both roles)
# What : OS prerequisites for kubeadm - packages, swap off, kernel modules, sysctl, time sync.
# Files: templates/system/{modules-k8s.conf,sysctl-k8s.conf}

install_packages() {
  apt_install curl ca-certificates gnupg apt-transport-https chrony socat conntrack ebtables ipset jq iproute2 ethtool
}

disable_swap() {          # Kubernetes requires swap off, now and after reboot
  swapoff -a
  sed -ri '/\sswap\s/ s/^([^#])/#\1/' /etc/fstab
  systemctl mask swap.target >/dev/null 2>&1 || true
  local unit
  for unit in $(systemctl list-units --type=swap --no-legend 2>/dev/null | awk '{print $1}'); do
    systemctl mask "$unit" >/dev/null 2>&1 || true
  done
}

configure_kernel() {
  install_file system/modules-k8s.conf /etc/modules-load.d/k8s.conf
  modprobe overlay
  modprobe br_netfilter
  install_file system/sysctl-k8s.conf /etc/sysctl.d/99-k8s.conf
  sysctl --system >/dev/null
}

enable_time_sync() { systemctl enable --now chrony >/dev/null 2>&1 || true; }

install_packages
disable_swap
configure_kernel
enable_time_sync
log "System prep done (swap off, kernel modules, sysctl, chrony)"
