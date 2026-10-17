#!/usr/bin/env bash
# Upgrade host-level components to the versions pinned in versions.env.
#   edit versions.env  ->  sudo ./update.sh status  ->  sudo ./update.sh <component|all>
# Cluster add-ons (Cilium, Argo CD, Envoy Gateway, ...) are GitOps: bump `targetRevision` in
# gitops/apps/*/*/application.yaml, commit & push; `./update.sh gitops` just pulls + refreshes Argo.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/config.sh"

usage() { cat <<USAGE
Usage: sudo ./update.sh [--dry-run] [--yes] [--no-drain] <command>
  status       pinned vs installed versions (read-only)
  check        newest upstream releases vs pinned (read-only, needs internet)
  repo         git pull this repo
  k8s          kubeadm/kubelet/kubectl upgrade (one minor at a time; master first)
  containerd   containerd.io to CONTAINERD_VERSION
  helm         helm binary to HELM_VERSION            (master)
  netbird      NetBird agent to NETBIRD_VERSION
  gitops       pull repo + hard-refresh Argo apps     (master; chart bumps are done in git)
  os           apt security/regular updates (held packages untouched), no reboot
  all          repo, containerd, helm, netbird, k8s, gitops
USAGE
}

DRY=0; NO_DRAIN=0; CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1;; --yes|-y) ASSUME_YES=1;; --no-drain) NO_DRAIN=1;;
    -h|--help) usage; exit 0;; *) CMD="$1";;
  esac; shift
done
[[ -n "$CMD" ]] || { usage; exit 1; }

if [[ -f /etc/kubernetes/admin.conf ]]; then ROLE=master
elif [[ -f /etc/kubernetes/kubelet.conf ]]; then ROLE=worker
else ROLE=none; fi
export KUBECONFIG=/etc/kubernetes/admin.conf
NODE_NAME="${NODE_NAME:-$(hostname)}"; NODE_NAME="${NODE_NAME,,}"
detect_arch

x() { if (( DRY )); then echo "DRY-RUN: $*"; else "$@"; fi; }   # run or just print
gh_latest() { curl -fsS --max-time 15 "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name 2>/dev/null || echo "?"; }
[[ $CMD == status || $CMD == check ]] || require_root

# ------------------------------------------------------------------------------------------
cmd_status() {
  printf '%-14s %-14s %s\n' COMPONENT PINNED INSTALLED
  printf '%-14s %-14s %s\n' kubeadm "$K8S_VERSION" "$(installed_version kubeadm)"
  printf '%-14s %-14s %s\n' kubelet "$K8S_VERSION" "$(installed_version kubelet)"
  printf '%-14s %-14s %s\n' containerd "$CONTAINERD_VERSION" "$(installed_version containerd.io)"
  printf '%-14s %-14s %s\n' netbird "$NETBIRD_VERSION" "$(installed_version netbird)"
  printf '%-14s %-14s %s\n' helm "$HELM_VERSION" "$(helm version --template '{{.Version}}' 2>/dev/null || echo -)"
  for a in cilium argocd envoy-gateway cert-manager; do
    printf '%-14s %-14s %s\n' "$a (git)" "$(app_chart_version gitops/apps/platform/$a)" "see: kubectl -n argocd get app $a"
  done
  if [[ $ROLE == master ]]; then echo; kubectl get nodes -o wide 2>/dev/null || true; fi
}

cmd_check() {
  echo "Newest upstream releases (informational):"
  printf '%-22s %-14s %s\n' COMPONENT PINNED LATEST
  printf '%-22s %-14s %s\n' "k8s ${K8S_MINOR} patch" "v$K8S_VERSION" "$(curl -fsS --max-time 15 "https://dl.k8s.io/release/stable-${K8S_MINOR}.txt")"
  printf '%-22s %-14s %s\n' "k8s newest minor" "v$K8S_VERSION" "$(curl -fsS --max-time 15 https://dl.k8s.io/release/stable.txt)  (check add-on support first!)"
  printf '%-22s %-14s %s\n' containerd "$CONTAINERD_VERSION" "$(gh_latest containerd/containerd)"
  printf '%-22s %-14s %s\n' helm "$HELM_VERSION" "$(gh_latest helm/helm)"
  printf '%-22s %-14s %s\n' netbird "$NETBIRD_VERSION" "$(gh_latest netbirdio/netbird)"
  printf '%-22s %-14s %s\n' cilium "$(app_chart_version gitops/apps/platform/cilium)" "$(gh_latest cilium/cilium)"
  printf '%-22s %-14s %s\n' envoy-gateway "$(app_chart_version gitops/apps/platform/envoy-gateway)" "$(gh_latest envoyproxy/gateway)"
  printf '%-22s %-14s %s\n' cert-manager "$(app_chart_version gitops/apps/platform/cert-manager)" "$(gh_latest cert-manager/cert-manager)"
  printf '%-22s %-14s %s\n' local-path-prov "$(grep -m1 'targetRevision: v' "$ROOT/gitops/apps/platform/local-path-provisioner/application.yaml" | awk '{print $2}')" "$(gh_latest rancher/local-path-provisioner)"
  printf '%-22s %-14s %s\n' "argo-cd chart" "$(app_chart_version gitops/apps/platform/argocd)" \
    "$(curl -fsS --max-time 20 https://argoproj.github.io/argo-helm/index.yaml | awk '/^  argo-cd:/{f=1} f&&/^    version:/&&!d{print $2; d=1}')"
}

cmd_repo() { x git -C "$ROOT" pull --ff-only; }

cmd_containerd() {
  local want; want="$(apt_version_for containerd.io "$CONTAINERD_VERSION")"
  [[ "$(installed_version containerd.io)" != "$want" ]] || { log "containerd already $want"; return; }
  confirm "Upgrade containerd.io to $want (restarts the container runtime)?" y || return 0
  x install_pinned containerd.io "$CONTAINERD_VERSION"
  x systemctl restart containerd
}

cmd_helm() {
  [[ $ROLE == master ]] || { log "helm only runs on the master."; return; }
  [[ "$(helm version --template '{{.Version}}' 2>/dev/null)" == "v$HELM_VERSION" ]] && { log "helm already v$HELM_VERSION"; return; }
  local tmp f; tmp="$(mktemp -d)"; f="helm-v$HELM_VERSION-linux-$ARCH.tar.gz"
  (( DRY )) && { echo "DRY-RUN: install helm v$HELM_VERSION"; return; }
  curl -fsSL "https://get.helm.sh/$f" -o "$tmp/$f"; curl -fsSL "https://get.helm.sh/$f.sha256sum" -o "$tmp/$f.sha256sum"
  (cd "$tmp" && sha256sum -c "$f.sha256sum"); tar -xzf "$tmp/$f" -C "$tmp"
  install -m 0755 "$tmp/linux-$ARCH/helm" /usr/local/bin/helm; rm -rf "$tmp"
}

cmd_netbird() {
  have netbird || { log "netbird not installed - skipping."; return; }
  x install_pinned netbird "$NETBIRD_VERSION"
}

cmd_gitops() {
  [[ $ROLE == master ]] || { log "gitops refresh runs on the master."; return; }
  cmd_repo
  for a in $(kubectl -n argocd get applications -o name 2>/dev/null); do
    x kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite
  done
  kubectl -n argocd get applications 2>/dev/null || true
  log "Chart bumps: edit targetRevision in gitops/apps/*/*/application.yaml, commit & push - Argo does the rest."
}

cmd_os() {
  x apt-get update -qq
  x env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  [[ -f /var/run/reboot-required ]] && warn "Reboot required - drain the node first (kubectl drain), then reboot."
  true
}

# ---- Kubernetes upgrade, split into small steps ----------------------------------------------
minor_of() { local v="${1%.*}"; echo "${v#*.}"; }          # 1.36.5 -> 36

k8s_check_upgrade_path() {  # $1 current, $2 target
  local step=$(( $(minor_of "$2") - $(minor_of "$1") ))
  (( step >= 0 )) || die "Downgrades are unsupported ($1 -> $2)."
  (( step <= 1 )) || die "kubeadm upgrades one minor at a time ($1 -> $2). Go through 1.$(( $(minor_of "$1") + 1 )) first."
}

k8s_check_master_is_ready() {  # workers may only upgrade after the control plane
  local api_ver
  api_ver="$(curl -fsSk --max-time 10 "https://$CONTROL_PLANE_ENDPOINT:6443/version" | jq -r .gitVersion | sed 's/^v//;s/[-+].*//')"
  [[ -n "$api_ver" ]] || die "Cannot read the API server version."
  [[ "$(minor_of "$api_ver")" -ge "$(minor_of "$1")" ]] || die "Upgrade the master first (API server is $api_ver, target $1)."
}

k8s_switch_apt_repo() {  # $1 = target minor, e.g. 1.37; only when the minor changes
  x rm -f /etc/apt/keyrings/kubernetes.gpg
  x add_apt_repo kubernetes "https://pkgs.k8s.io/core:/stable:/v$1/deb/Release.key" "https://pkgs.k8s.io/core:/stable:/v$1/deb/ /"
}

k8s_drain_self() {
  (( NO_DRAIN )) && return 0
  if [[ $ROLE == master ]]; then
    x kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --timeout=300s || warn "drain incomplete; continuing"
  elif [[ "${ASSUME_YES:-0}" != 1 ]]; then
    confirm "Did you run 'kubectl drain $NODE_NAME --ignore-daemonsets --delete-emptydir-data' on the master?" n || die "Drain first (or use --no-drain)."
  fi
}

k8s_upgrade_control_plane() { x kubeadm upgrade plan; x kubeadm upgrade apply "v$1" -y; }
k8s_upgrade_worker()        { x kubeadm upgrade node; }

k8s_upgrade_node_packages() {
  local pkg
  for pkg in kubelet kubectl; do x install_pinned "$pkg" "$1"; done
  x apt-mark hold kubeadm kubelet kubectl
  x systemctl daemon-reload
  x systemctl restart kubelet
}

k8s_uncordon_self() {
  if [[ $ROLE == master ]]; then (( NO_DRAIN )) || x kubectl uncordon "$NODE_NAME"
  else log "Now run on the master: kubectl uncordon $NODE_NAME"; fi
}

cmd_k8s() {
  [[ $ROLE != none ]] || die "This node is not part of a cluster."
  local current target="$K8S_VERSION"
  current="$(kubeadm version -o short | sed 's/^v//')"
  if [[ "$current" == "$target" && "$(installed_version kubelet | cut -d- -f1)" == "$target" ]]; then
    log "Kubernetes already $target"; return
  fi
  k8s_check_upgrade_path "$current" "$target"
  [[ $ROLE != worker ]] || k8s_check_master_is_ready "$target"

  log "Upgrading Kubernetes $current -> $target on $ROLE ($NODE_NAME)"
  confirm "Proceed?" y || return 0

  [[ "${current%.*}" == "${target%.*}" ]] || k8s_switch_apt_repo "${target%.*}"
  x apt-get update -qq
  x install_pinned kubeadm "$target"           # kubeadm first: it drives the rest

  if [[ $ROLE == master ]]; then
    k8s_upgrade_control_plane "$target"; k8s_drain_self
  else
    k8s_drain_self; k8s_upgrade_worker
  fi
  k8s_upgrade_node_packages "$target"
  k8s_uncordon_self
  log "Kubernetes $target done on $NODE_NAME."
}

case "$CMD" in
  status) cmd_status;; check) cmd_check;; repo) cmd_repo;; k8s) cmd_k8s;;
  containerd) cmd_containerd;; helm) cmd_helm;; netbird) cmd_netbird;;
  gitops|cilium|argocd|envoy|envoy-gateway) cmd_gitops;; os) cmd_os;;
  all) cmd_repo; source "$ROOT/lib/config.sh"; cmd_containerd; cmd_helm; cmd_netbird; cmd_k8s; cmd_gitops;;
  *) usage; exit 1;;
esac
