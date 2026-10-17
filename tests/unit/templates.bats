#!/usr/bin/env bats
# Templates must render to valid files with every ${VAR} filled in.
load helpers
setup() {
  setup_env
  export MASTER_IP=192.168.0.160 NODE_IP=192.168.0.161 NODE_NAME=dell NODE_LABELS="homelab/role=master,homelab/disk=ssd"
  export K8S_VERSION=1.36.5 CONTROL_PLANE_ENDPOINT=k8s-api.example.org POD_CIDR=10.244.0.0/16 SERVICE_CIDR=10.96.0.0/12
  export JOIN_TOKEN=abcdef.0123456789abcdef ENCRYPTION_KEY=c2VjcmV0
}
teardown() { teardown_env; }

yaml_docs() { python3 -c 'import sys,yaml; print(" ".join(d["kind"] for d in yaml.safe_load_all(sys.stdin)))'; }

@test "kubeadm-init renders (with Secrets encryption)" {
  APISERVER_EXTRA="$(cat "$ROOT/templates/kubernetes/apiserver-encryption.yaml")"; export APISERVER_EXTRA
  out="$(render kubernetes/kubeadm-init.yaml)"
  [ "$(yaml_docs <<<"$out")" = "InitConfiguration ClusterConfiguration" ]
  ! grep -q '\${' <<<"$out"
  grep -q 'encryption-provider-config' <<<"$out"
  grep -q 'controlPlaneEndpoint: "k8s-api.example.org:6443"' <<<"$out"
}
@test "kubeadm-init renders without encryption and keeps the master schedulable" {
  APISERVER_EXTRA=""; export APISERVER_EXTRA
  out="$(render kubernetes/kubeadm-init.yaml)"
  [ "$(yaml_docs <<<"$out")" = "InitConfiguration ClusterConfiguration" ]
  ! grep -q 'encryption-provider-config' <<<"$out"
  grep -q 'taints: \[\]' <<<"$out"
  grep -q 'addon/kube-proxy' <<<"$out"
}
@test "kubeadm-join renders with a CA hash" {
  CA_VERIFY='caCertHashes: [sha256:0123abcd]'; export CA_VERIFY
  out="$(render kubernetes/kubeadm-join.yaml)"
  [ "$(yaml_docs <<<"$out")" = "JoinConfiguration" ]
  grep -q 'caCertHashes' <<<"$out"
  ! grep -q '\${' <<<"$out"
}
@test "kubeadm-join renders with unsafe CA skip" {
  CA_VERIFY='unsafeSkipCAVerification: true'; export CA_VERIFY
  out="$(render kubernetes/kubeadm-join.yaml)"
  [ "$(yaml_docs <<<"$out")" = "JoinConfiguration" ]
  grep -q 'unsafeSkipCAVerification: true' <<<"$out"
}
@test "encryption-config renders" {
  out="$(render kubernetes/encryption-config.yaml)"
  [ "$(yaml_docs <<<"$out")" = "EncryptionConfiguration" ]
  grep -q 'secret: c2VjcmV0' <<<"$out"
}
@test "install_rendered reports whether the file changed" {
  CA_VERIFY='unsafeSkipCAVerification: true'; export CA_VERIFY
  install_rendered kubernetes/kubeadm-join.yaml "$TMP/join.yaml" 600
  [ "$CHANGED" = 1 ]
  install_rendered kubernetes/kubeadm-join.yaml "$TMP/join.yaml" 600
  [ "$CHANGED" = 0 ]
  [ "$(stat -c %a "$TMP/join.yaml")" = "600" ]
}
@test "install_file copies static templates and reports changes" {
  install_file system/sysctl-k8s.conf "$TMP/sysctl.conf"
  [ "$CHANGED" = 1 ]
  grep -q 'net.ipv4.ip_forward = 1' "$TMP/sysctl.conf"
  install_file system/sysctl-k8s.conf "$TMP/sysctl.conf"
  [ "$CHANGED" = 0 ]
}
@test "every file in templates/ exists and is non-empty" {
  while IFS= read -r f; do [ -s "$f" ]; done < <(find "$ROOT/templates" -type f)
}
