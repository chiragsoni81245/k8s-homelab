#!/usr/bin/env bats
# Unit tests for lib/common.sh helpers.
load helpers
setup()    { setup_env; }
teardown() { teardown_env; }

# ---- validators ----
@test "is_ipv4 accepts valid addresses" {
  is_ipv4 192.168.0.160
  is_ipv4 10.0.0.1
}
@test "is_ipv4 rejects invalid addresses" {
  ! is_ipv4 300.1.1.1
  ! is_ipv4 192.168.0
  ! is_ipv4 not-an-ip
}
@test "is_host_or_ip accepts hostnames and IPs, rejects junk" {
  is_host_or_ip k8s-api.homelab.chiragsoni.org
  is_host_or_ip 192.168.0.160
  ! is_host_or_ip "bad host!"
  ! is_host_or_ip "-leading-dash"
}

# ---- write_file ----
@test "write_file creates a file and returns 0 when content changes" {
  run bash -c "source '$ROOT/lib/common.sh'; echo hello | write_file '$TMP/a/b.conf' 600"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/a/b.conf")" = "hello" ]
  [ "$(stat -c %a "$TMP/a/b.conf")" = "600" ]
}
@test "write_file returns 1 and leaves the file alone when unchanged" {
  echo hello | write_file "$TMP/f"
  run bash -c "source '$ROOT/lib/common.sh'; echo hello | write_file '$TMP/f'"
  [ "$status" -eq 1 ]
}
@test "write_file replaces changed content" {
  echo one | write_file "$TMP/f"
  echo two | write_file "$TMP/f"
  [ "$(cat "$TMP/f")" = "two" ]
}

# ---- config_set ----
@test "config_set adds, updates and locks down permissions" {
  config_set FOO bar
  config_set BAZ qux
  config_set FOO changed
  [ "$(grep -c '^FOO=' "$CONFIG_FILE")" -eq 1 ]
  grep -q '^FOO=changed$' "$CONFIG_FILE"
  grep -q '^BAZ=qux$' "$CONFIG_FILE"
  [ "$(stat -c %a "$CONFIG_FILE")" = "600" ]
}

# ---- ensure_hosts_entry ----
@test "ensure_hosts_entry adds an entry and keeps other lines" {
  printf '127.0.0.1 localhost\n' >"$HOSTS_FILE"
  ensure_hosts_entry 192.168.0.160 k8s-api.example.org
  grep -q '^127.0.0.1 localhost$' "$HOSTS_FILE"
  grep -q '^192.168.0.160 k8s-api.example.org' "$HOSTS_FILE"
}
@test "ensure_hosts_entry replaces (never duplicates) an existing name" {
  printf '10.0.0.1 k8s-api.example.org\n' >"$HOSTS_FILE"
  ensure_hosts_entry 192.168.0.160 k8s-api.example.org
  ensure_hosts_entry 192.168.0.161 k8s-api.example.org
  [ "$(grep -c 'k8s-api.example.org' "$HOSTS_FILE")" -eq 1 ]
  grep -q '^192.168.0.161 ' "$HOSTS_FILE"
}
@test "ensure_hosts_entry does not touch similarly named hosts" {
  printf '10.0.0.9 other-k8s-api.example.org\n' >"$HOSTS_FILE"
  ensure_hosts_entry 192.168.0.160 k8s-api.example.org
  grep -q 'other-k8s-api.example.org' "$HOSTS_FILE"
}

# ---- prompts (non-interactive mode) ----
@test "prompt uses the default in non-interactive mode" {
  unset FOO
  prompt FOO "question" "the-default"
  [ "$FOO" = "the-default" ]
}
@test "prompt keeps a value already set in the environment" {
  FOO=preset
  prompt FOO "question" "the-default"
  [ "$FOO" = "preset" ]
}
@test "prompt fails without a default in non-interactive mode" {
  unset FOO
  run bash -c "export NONINTERACTIVE=1 LOG_FILE='$LOG_FILE'; source '$ROOT/lib/common.sh'; prompt FOO 'question'"
  [ "$status" -ne 0 ]
}
@test "confirm follows its default in non-interactive mode" {
  confirm "ok?" y
  ! confirm "ok?" n
}
@test "ask_default does not ask when the answer is already saved" {
  config_set CONTROL_PLANE_ENDPOINT saved.example.org
  CONTROL_PLANE_ENDPOINT=saved.example.org
  NONINTERACTIVE=0 ask_default CONTROL_PLANE_ENDPOINT "q"      # would block on a TTY if it asked
  [ "$CONTROL_PLANE_ENDPOINT" = "saved.example.org" ]
}

# ---- apt_version_for / app_chart_version ----
@test "app_chart_version reads the pinned chart version from application.yaml" {
  mkdir -p "$TMP/repo/gitops/apps/platform/demo"
  cat >"$TMP/repo/gitops/apps/platform/demo/application.yaml" <<'YAML'
spec:
  sources:
    - repoURL: https://charts.example.org
      chart: demo
      targetRevision: 9.8.7   # pinned
    - repoURL: https://github.com/x/y.git
      targetRevision: main
      ref: values
YAML
  REPO_ROOT="$TMP/repo"
  [ "$(app_chart_version gitops/apps/platform/demo)" = "9.8.7" ]
}
@test "app_chart_version works for every real platform chart app" {
  for app in cilium argocd envoy-gateway; do
    v="$(app_chart_version gitops/apps/platform/$app)"
    [[ "$v" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "$app -> '$v'"; false; }
  done
}

# ---- retry ----
@test "retry succeeds once the command succeeds" {
  calls=0
  flaky() { calls=$((calls+1)); [ "$calls" -ge 3 ]; }
  retry 5 0 flaky
  [ "$calls" -eq 3 ]
}
@test "retry gives up after N attempts" {
  ! retry 2 0 false
}
