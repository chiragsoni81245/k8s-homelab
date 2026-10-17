#!/usr/bin/env bats
# Invariants of the GitOps tree and of the repo-wide configuration.
load helpers
setup()    { setup_env; }
teardown() { teardown_env; }

@test "every application.yaml is an Argo Application with a project and a resources finalizer" {
  while IFS= read -r f; do
    python3 - "$f" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["kind"] == "Application", "kind"
assert d["spec"]["project"], "project"
assert "resources-finalizer.argocd.argoproj.io" in d["metadata"]["finalizers"], "finalizer"
PY
  done < <(find "$ROOT/gitops/apps" -name application.yaml)
}

@test "own-repo URL and branch are tagged and identical everywhere" {
  urls="$(grep -rh '# homelab-repo' "$ROOT/gitops" | awk '{print $NF=="homelab-repo" ? $(NF-2) : ""}' | sort -u)"
  [ "$(wc -l <<<"$urls")" -eq 1 ]
  revs="$(grep -rh '# homelab-revision' "$ROOT/gitops" | awk '{print $(NF-2)}' | sort -u)"
  [ "$(wc -l <<<"$revs")" -eq 1 ]
}

@test "set-repo-url.sh rewrites every tagged line (run on a copy)" {
  mkdir -p "$TMP/copy/tools"
  cp -r "$ROOT/gitops" "$TMP/copy/"
  cp "$ROOT/tools/set-repo-url.sh" "$TMP/copy/tools/"
  "$TMP/copy/tools/set-repo-url.sh" git@github.com:me/fork.git dev >/dev/null
  total="$(grep -rc '# homelab-repo' "$TMP/copy/gitops" | awk -F: '{s+=$2} END{print s}')"
  ok="$(grep -rh '# homelab-repo' "$TMP/copy/gitops" | grep -c 'git@github.com:me/fork.git')"
  [ "$total" -gt 0 ] && [ "$total" -eq "$ok" ]
  ! grep -rh '# homelab-revision' "$TMP/copy/gitops" | grep -qv 'targetRevision: dev'
}

@test "root app picks up application.yaml files recursively" {
  grep -q "include: '\*\*/application.yaml'" "$ROOT/gitops/bootstrap/root-app.yaml"
  grep -q 'recurse: true' "$ROOT/gitops/bootstrap/root-app.yaml"
}

@test "cilium k8sServiceHost matches the default control-plane endpoint" {
  grep -qE "^k8sServiceHost:[[:space:]]*$CONTROL_PLANE_ENDPOINT\$" "$ROOT/gitops/apps/platform/cilium/values.yaml"
}

@test "LB pool contains the fixed gateway IP" {
  python3 - "$ROOT" <<'PY'
import sys, ipaddress, yaml, re
root = sys.argv[1]
pool = yaml.safe_load(open(f"{root}/gitops/apps/platform/cilium/lb-ippool.yaml"))["spec"]["blocks"][0]
gw = open(f"{root}/gitops/apps/platform/envoy-gateway/gateway.yaml").read()
ip = ipaddress.ip_address(re.search(r"lbipam.cilium.io/ips:\s*(\S+)", gw).group(1))
assert ipaddress.ip_address(pool["start"]) <= ip <= ipaddress.ip_address(pool["stop"]), "gateway IP outside the pool"
PY
}

@test "static PV is pinned to the media node and never pruned" {
  grep -q 'homelab/storage' "$ROOT/gitops/apps/platform/local-storage/data-pv.yaml"
  grep -q 'prune: false' "$ROOT/gitops/apps/platform/local-storage/application.yaml"
}

@test "versions.env defines every pinned host version" {
  for v in K8S_VERSION CONTAINERD_VERSION HELM_VERSION NETBIRD_VERSION; do
    [[ -n "${!v}" ]] || { echo "$v missing"; false; }
  done
  [[ "$K8S_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "update.sh prints usage and fails without a command" {
  run "$ROOT/update.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}
@test "update.sh status works without root or a cluster" {
  run "$ROOT/update.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"kubeadm"* ]]
}
@test "setup.sh refuses to run without root" {
  [ "$EUID" -ne 0 ] || skip "running as root"
  run "$ROOT/setup.sh" --role worker
  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
}
