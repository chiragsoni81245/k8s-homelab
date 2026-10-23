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
pool = yaml.safe_load(open(f"{root}/gitops/apps/platform/cilium/manifests/ciliumloadbalancerippool-homelab.yaml"))["spec"]["blocks"][0]
gw = open(f"{root}/gitops/apps/platform/envoy-gateway/manifests/envoyproxy-homelab.yaml").read()
ip = ipaddress.ip_address(re.search(r"lbipam.cilium.io/ips:\s*(\S+)", gw).group(1))
assert ipaddress.ip_address(pool["start"]) <= ip <= ipaddress.ip_address(pool["stop"]), "gateway IP outside the pool"
PY
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

# Every app that brings its own local volume must follow the same safe pattern.
@test "every PV is a pinned, retained local-data volume with a matching claim" {
  python3 - "$ROOT" <<'PY'
import sys, glob, yaml
root = sys.argv[1] + "/gitops/apps"
pvs, pvcs = {}, []
for f in glob.glob(root + "/**/*.yaml", recursive=True):
    for d in yaml.safe_load_all(open(f)):
        if not isinstance(d, dict): continue
        if d.get("kind") == "PersistentVolume": pvs[d["metadata"]["name"]] = d
        if d.get("kind") == "PersistentVolumeClaim": pvcs.append(d)
assert pvs, "expected at least one PV"
for name, pv in pvs.items():
    sp = pv["spec"]
    assert sp["storageClassName"] == "local-data", f"{name}: storage class"
    assert sp["persistentVolumeReclaimPolicy"] == "Retain", f"{name}: must Retain"
    assert sp["local"]["path"].startswith("/DATA/"), f"{name}: path must be under /DATA"
    terms = sp["nodeAffinity"]["required"]["nodeSelectorTerms"]
    assert "homelab/storage" in str(terms), f"{name}: not pinned to the media node"
for pvc in pvcs:
    vn = pvc["spec"].get("volumeName")
    if vn:
        assert vn in pvs, f"PVC {pvc['metadata']['name']} -> unknown PV {vn}"
        assert pvc["spec"]["storageClassName"] == pvs[vn]["spec"]["storageClassName"], "class mismatch"
used = {p["spec"].get("volumeName") for p in pvcs}
assert set(pvs) <= used, f"PVs without a claim: {set(pvs) - used}"
PY
}

@test "jellyfin uses claims that exist in its own namespace" {
  python3 - "$ROOT" <<'PY'
import sys, yaml, glob
root = sys.argv[1] + "/gitops/apps/workloads/jellyfin"
vals = yaml.safe_load(open(root + "/values.yaml"))
app  = yaml.safe_load(open(root + "/application.yaml"))
ns   = app["spec"]["destination"]["namespace"]
claims = {d["metadata"]["name"]: d for f in glob.glob(root + "/manifests/*.yaml") for d in yaml.safe_load_all(open(f))
          if d and d.get("kind") == "PersistentVolumeClaim"}
for key in ("config", "media"):
    name = vals["persistence"][key]["existingClaim"]
    assert name in claims, f"{key}: claim {name} not defined in manifests/"
    assert claims[name]["metadata"]["namespace"] == ns, f"{key}: wrong namespace"
PY
}

@test "no leftover generic shared data-pv anywhere" {
  ! grep -rq 'data-pv' "$ROOT/gitops" "$ROOT/docs"
}

@test "TLS chain is consistent: issuer -> certificate -> gateway listener" {
  python3 - "$ROOT" <<'PY'
import sys, yaml, glob
root = sys.argv[1] + "/gitops/apps/platform"
docs = [d for f in glob.glob(root + "/*/manifests/*.yaml") for d in yaml.safe_load_all(open(f)) if d]
issuers = {d["metadata"]["name"]: d for d in docs if d["kind"] == "ClusterIssuer"}
cert = [d for d in docs if d["kind"] == "Certificate"][0]
gw = [d for d in docs if d["kind"] == "Gateway"][0]
assert {"letsencrypt-staging", "letsencrypt-prod"} <= set(issuers), "missing issuer"
for name, i in issuers.items():
    ref = i["spec"]["acme"]["solvers"][0]["dns01"]["cloudflare"]["apiTokenSecretRef"]
    assert ref == {"name": "cloudflare-api-token", "key": "api-token"}, f"{name}: token secret ref"
assert cert["spec"]["issuerRef"]["name"] in issuers, "certificate uses unknown issuer"
https = [l for l in gw["spec"]["listeners"] if l["protocol"] == "HTTPS"][0]
assert https["tls"]["certificateRefs"][0]["name"] == cert["spec"]["secretName"], "gateway secret != certificate secret"
assert cert["metadata"]["namespace"] == gw["metadata"]["namespace"], "certificate must live with the gateway"
assert https["hostname"] in cert["spec"]["dnsNames"], "listener hostname not covered by the certificate"
PY
}

@test "app hostnames are covered by the wildcard certificate (one level only)" {
  python3 - "$ROOT" <<'PY'
import sys, yaml, glob
root = sys.argv[1] + "/gitops/apps"
for f in glob.glob(root + "/workloads/*/values.yaml"):
    v = yaml.safe_load(open(f))
    for h in (v.get("httpRoute") or {}).get("hostnames", []):
        assert h.endswith(".chiragsoni.org") and h.count(".") == 2, f"{f}: {h} not matched by *.chiragsoni.org"
PY
}

<<<<<<< Updated upstream
@test "plain manifests: one resource per file, named <kind>-<name>.yaml, under <app>/manifests/" {
  python3 - "$ROOT" <<'PY'
import sys, os, glob, yaml
root = sys.argv[1] + "/gitops/apps"
files = glob.glob(root + "/*/*/manifests/*.yaml")
assert files, "no manifests found"
for f in files:
    docs = [d for d in yaml.safe_load_all(open(f)) if d]
    assert len(docs) == 1, f"{f}: {len(docs)} resources (split them)"
    d = docs[0]
    want = f"{d['kind'].lower()}-{d['metadata']['name']}.yaml"
    assert os.path.basename(f) == want, f"{f}: expected file name {want}"
# app folders hold only application.yaml / values.yaml (+ subfolders); other manifests belong in manifests/
for f in glob.glob(root + "/*/*/*.yaml"):
    assert os.path.basename(f) in ("application.yaml", "values.yaml"), f"{f}: move it to manifests/"
PY
=======
@test "nothing in the repo assumes node names or NIC names" {
  # no role-based hostnames in scripts, no NIC-name patterns in the L2 policy
  ! grep -rniE "\bdell\b|\basus\b" "$ROOT/scripts" "$ROOT/lib" "$ROOT/setup.sh" "$ROOT/update.sh" "$ROOT/install.sh" "$ROOT/tools"
  ! grep -qE '^[[:space:]]+interfaces:' "$ROOT/gitops/apps/platform/cilium/l2-announcement.yaml"
>>>>>>> Stashed changes
}
