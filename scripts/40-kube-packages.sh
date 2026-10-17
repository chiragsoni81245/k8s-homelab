#!/usr/bin/env bash
# 40-kube-packages.sh - sourced by setup.sh (both roles)
# What : kubeadm / kubelet / kubectl pinned to K8S_VERSION (versions.env) and held.

add_kubernetes_repo() {
  add_apt_repo kubernetes "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
    "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /"
}

add_kubernetes_repo
for pkg in kubelet kubeadm kubectl; do install_pinned "$pkg" "$K8S_VERSION"; done
systemctl enable kubelet >/dev/null 2>&1
