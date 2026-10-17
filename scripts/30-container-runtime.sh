#!/usr/bin/env bash
# 30-container-runtime.sh - sourced by setup.sh (both roles)
# What : containerd.io (version from versions.env) configured for systemd cgroups.
# Files: templates/system/crictl.yaml

add_containerd_repo() {
  . /etc/os-release
  add_apt_repo docker https://download.docker.com/linux/ubuntu/gpg \
    "https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable"
}

configure_containerd() {
  mkdir -p /etc/containerd
  containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' \
    | write_file /etc/containerd/config.toml && systemctl restart containerd || true
  systemctl enable --now containerd >/dev/null 2>&1
  install_file system/crictl.yaml /etc/crictl.yaml
}

add_containerd_repo
install_pinned containerd.io "$CONTAINERD_VERSION"
configure_containerd
