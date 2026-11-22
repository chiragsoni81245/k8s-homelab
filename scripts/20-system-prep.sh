#!/usr/bin/env bash
# 20-system-prep.sh - sourced by setup.sh (both roles)
# What : OS prerequisites for kubeadm - packages, swap off, kernel modules, sysctl, time sync; on a spinning
#        root disk also fewer/rarer disk writes (tune_for_hdd).
# Files: templates/system/{modules-k8s.conf,sysctl-k8s.conf,journald-homelab-hdd.conf}

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

# add_mount_options MOUNTPOINT OPTS... : add OPTS to MOUNTPOINT's /etc/fstab line (ext4 only, idempotent), then
# remount so they apply now. A timestamped backup of fstab is kept.
add_mount_options() {
  local mnt="$1" opt missing=() current
  shift
  [[ "$(findmnt -no FSTYPE "$mnt" 2>/dev/null)" == ext4 ]] || { warn "$mnt is not ext4 - mount options left alone"; return 0; }
  current="$(awk -v m="$mnt" '$1 !~ /^#/ && $2 == m {print $4; exit}' /etc/fstab)"
  [[ -n "$current" ]] || { warn "$mnt has no /etc/fstab line - mount options left alone"; return 0; }
  for opt in "$@"; do [[ ",$current," == *",${opt%%=*}"[,=]* ]] || missing+=("$opt"); done
  (( ${#missing[@]} )) || return 0
  cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  local add; add="$(IFS=,; echo "${missing[*]}")"
  awk -v m="$mnt" -v add="$add" 'BEGIN{OFS="\t"} $1 !~ /^#/ && $2 == m && !done {$4 = $4 "," add; done=1} {print}' \
    /etc/fstab >/etc/fstab.new && mv /etc/fstab.new /etc/fstab
  systemctl daemon-reload
  mount -o "remount,$add" "$mnt"
  log "$mnt: added mount options $add"
}

# Spinning root disk: etcd, containerd, journald and ext4's own journal all force small writes onto it, and every
# one waits for the disk head (the cause of a high load average with idle CPUs). Write less and less often.
# Trade-off accepted for a homelab: a crash/power cut can lose up to ~60s of recent non-fsynced writes (logs etc.;
# etcd still fsyncs its own writes) and host logs no longer survive a reboot.
tune_for_hdd() {
  [[ "$(disk_kind)" == hdd ]] || return 0
  # noatime: reads no longer cause writes. commit=60: ext4 journal flushed every 60s instead of 5s.
  add_mount_options / noatime commit=60
  install_file system/journald-homelab-hdd.conf /etc/systemd/journald.conf.d/homelab-hdd.conf
  (( CHANGED )) && systemctl restart systemd-journald
  log "HDD root disk: noatime + commit=60 on /, journal kept in RAM"
}

install_packages
disable_swap
configure_kernel
enable_time_sync
tune_for_hdd
log "System prep done (swap off, kernel modules, sysctl, chrony)"
