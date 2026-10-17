#!/usr/bin/env bash
# 55-master-bootstrap.sh - sourced by setup.sh (master only)
# What : install the two things Argo CD needs before it can run, then hand over to GitOps:
#          helm -> Cilium (CNI) -> Argo CD -> repo credential -> root app-of-apps.
#        Cilium/Argo versions come from gitops/apps/platform/*/application.yaml, and values from the
#        same values.yaml Argo uses later, so bootstrap and GitOps never drift apart.
export KUBECONFIG=/etc/kubernetes/admin.conf
GITOPS_DIR="$REPO_ROOT/gitops"
PLATFORM_DIR="$GITOPS_DIR/apps/platform"

install_helm() {
  local current archive tmp
  current="$(helm version --template '{{.Version}}' 2>/dev/null || true)"
  [[ "$current" != "v$HELM_VERSION" ]] || { log "helm $current already installed"; return 0; }
  archive="helm-v$HELM_VERSION-linux-$ARCH.tar.gz"; tmp="$(mktemp -d)"
  curl -fsSL "https://get.helm.sh/$archive"           -o "$tmp/$archive"
  curl -fsSL "https://get.helm.sh/$archive.sha256sum" -o "$tmp/$archive.sha256sum"
  (cd "$tmp" && sha256sum -c "$archive.sha256sum")
  tar -xzf "$tmp/$archive" -C "$tmp"
  install -m 0755 "$tmp/linux-$ARCH/helm" /usr/local/bin/helm
  rm -rf "$tmp"
}

# Ask which repo/branch Argo should pull; rewrite gitops/ locally if it differs from what is committed.
choose_gitops_repo() {
  local committed
  committed="$(grep -h '# homelab-repo' "$GITOPS_DIR/bootstrap/root-app.yaml" | awk '{print $2; exit}')"
  GITOPS_REPO_URL="${GITOPS_REPO_URL:-$committed}"
  ask_default GITOPS_REPO_URL "GitOps repo URL for Argo CD (https = public, git@... = needs a deploy key)"
  ask_default GITOPS_REVISION "GitOps branch/tag"
  if [[ "$GITOPS_REPO_URL" != "$committed" || "$GITOPS_REVISION" != main ]]; then
    warn "Repo/branch differ from what is committed in gitops/ - rewriting locally."
    warn "Commit and push that change to $GITOPS_REPO_URL ($GITOPS_REVISION) or Argo cannot find its apps."
    "$REPO_ROOT/tools/set-repo-url.sh" "$GITOPS_REPO_URL" "$GITOPS_REVISION"
  fi
}

check_committed_values() {
  grep -qE "^k8sServiceHost:[[:space:]]*\"?$CONTROL_PLANE_ENDPOINT\"?" "$PLATFORM_DIR/cilium/values.yaml" \
    || die "cilium/values.yaml k8sServiceHost != $CONTROL_PLANE_ENDPOINT. Edit it, commit, push, re-run."
  log "LB IP pool (from git): $(awk '/start:|stop:/ {printf "%s ", $2}' "$PLATFORM_DIR/cilium/lb-ippool.yaml")"
}

# True once Argo CD has an Application with this name: from then on GitOps owns it, and a helm upgrade
# would fight Argo over field ownership (server-side apply conflicts).
managed_by_argocd() { kubectl -n argocd get application "$1" >/dev/null 2>&1; }

# helm_install RELEASE REPO_NAME REPO_URL CHART APP_DIR NAMESPACE
helm_install() {
  local release="$1" repo_name="$2" repo_url="$3" chart="$4" app_dir="$5" namespace="$6" version
  if managed_by_argocd "$release"; then
    log "$release is managed by Argo CD - skipping helm (change it in git instead)."
    return 0
  fi
  version="$(app_chart_version "gitops/apps/platform/$app_dir")"
  [[ -n "$version" ]] || die "Cannot read the $release chart version from application.yaml"
  helm repo add "$repo_name" "$repo_url" >/dev/null 2>&1 || true
  helm repo update "$repo_name" >/dev/null
  step "$release chart $version"
  helm upgrade --install "$release" "$repo_name/$chart" --version "$version" \
    --namespace "$namespace" --create-namespace \
    -f "$PLATFORM_DIR/$app_dir/values.yaml" --wait --timeout 10m
}

install_cilium() {
  helm_install cilium cilium https://helm.cilium.io cilium cilium kube-system
  kubectl wait --for=condition=Ready "node/$NODE_NAME" --timeout=300s
}

install_argocd() { helm_install argocd argo https://argoproj.github.io/argo-helm argo-cd argocd argocd; }

# Only needed for ssh/private repos. The key is read from a file you point to; it is never stored in git.
create_repo_credential() {
  [[ "$GITOPS_REPO_URL" == git@* || "$GITOPS_REPO_URL" == ssh://* ]] || return 0
  prompt GITOPS_DEPLOY_KEY "Path to the READ-ONLY deploy key (private key file) for $GITOPS_REPO_URL"
  [[ -r "$GITOPS_DEPLOY_KEY" ]] || die "Cannot read $GITOPS_DEPLOY_KEY"
  kubectl -n argocd create secret generic homelab-repo --from-literal=type=git \
    --from-literal=url="$GITOPS_REPO_URL" --from-file=sshPrivateKey="$GITOPS_DEPLOY_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n argocd label secret homelab-repo argocd.argoproj.io/secret-type=repository --overwrite
}

apply_root_app() {
  step "Applying gitops/bootstrap (AppProject + root app)"
  kubectl apply -f "$GITOPS_DIR/bootstrap/"
}

apps_status() {  # lines like "cilium=Synced/Healthy"
  kubectl -n argocd get applications \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null || true
}

# Waits for every Argo app to be Synced/Healthy, printing progress. Never fatal: Argo keeps syncing in the
# background either way. ARGO_WAIT_TIMEOUT seconds (default 600); 0 = don't wait.
wait_for_apps() {
  local timeout="${ARGO_WAIT_TIMEOUT:-600}" deadline status not_ready
  if (( timeout == 0 )); then log "Not waiting for Argo apps (ARGO_WAIT_TIMEOUT=0). Watch: kubectl -n argocd get applications"; return 0; fi
  log "Waiting up to $((timeout/60)) min for Argo apps to sync (Ctrl-C is safe: Argo continues on its own)..."
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    status="$(apps_status)"
    not_ready="$(grep -v '=Synced/Healthy$' <<<"$status" || true)"
    if [[ -n "$status" && -z "$not_ready" ]]; then log "All Argo apps are Synced/Healthy."; break; fi
    log "Still syncing: $(tr '\n' ' ' <<<"${not_ready:-<no apps yet>}")"
    sleep 20
  done
  kubectl -n argocd get applications || true
}

write_join_info() {
  local argo_pw join_cmd
  argo_pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  join_cmd="$(kubeadm token create --ttl "${JOIN_TOKEN_TTL:-24h0m0s}" --print-join-command)"
  umask 077
  cat >/root/k8s-join-info.txt <<INFO
Generated $(date -Is)
Control-plane endpoint : $CONTROL_PLANE_ENDPOINT ($MASTER_IP)
Worker join command    : $join_cmd
  (token expires; regenerate: kubeadm token create --print-join-command)
Argo CD admin password : ${argo_pw:-<initial secret already removed>}
Argo CD UI             : kubectl -n argocd port-forward svc/argocd-server 8080:80  ->  http://localhost:8080  (user: admin)
INFO
  echo; cat /root/k8s-join-info.txt; echo
  log "Saved to /root/k8s-join-info.txt. On the worker run setup.sh, choose 'worker' (asks master IP, token, CA hash)."
}

install_helm
choose_gitops_repo
check_committed_values
install_cilium
install_argocd
create_repo_credential
apply_root_app
wait_for_apps
write_join_info
