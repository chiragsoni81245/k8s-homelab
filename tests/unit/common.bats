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

# ---- wireless toggle ----
@test "wireless_should_be_disabled honours yes/no" {
  DISABLE_WIRELESS=yes; wireless_should_be_disabled
  DISABLE_WIRELESS=no;  ! wireless_should_be_disabled
}
@test "wireless_should_be_disabled in auto mode follows the hardware" {
  DISABLE_WIRELESS=auto
  has_wireless_hardware() { return 1; }; ! wireless_should_be_disabled
  has_wireless_hardware() { return 0; };   wireless_should_be_disabled
}

# ---- disk detection and node labels (findmnt/lsblk are stubbed) ----
stub_root_disks() {  # args: lines like "part 1" "disk 1" -> what `lsblk -s -n -o TYPE,ROTA <root>` would print
  STUB_LSBLK="$(printf '%s\n' "$@")"
  findmnt() { echo "/dev/mapper/ubuntu--vg-ubuntu--lv"; }
  lsblk()   { printf '%s\n' "$STUB_LSBLK"; }
}

@test "disk_kind: HDD under LVM is detected as hdd (not guessed as ssd)" {
  stub_root_disks "lvm 1" "part 1" "disk 1"
  [ "$(disk_kind)" = hdd ]
}
@test "disk_kind: NVMe/SSD is detected as ssd" {
  stub_root_disks "part 0" "disk 0"
  [ "$(disk_kind)" = ssd ]
}
@test "disk_kind: any rotational disk under the root makes it hdd" {
  stub_root_disks "lvm 0" "disk 0" "disk 1"
  [ "$(disk_kind)" = hdd ]
}
@test "disk_kind prints nothing when it cannot tell" {
  stub_root_disks "lvm 0" "part 0"          # no whole-disk line
  [ -z "$(disk_kind)" ]
  findmnt() { return 1; }
  [ -z "$(disk_kind)" ]
}

@test "node_labels adds the disk label only when detected" {
  has_data_mount() { return 1; }
  disk_kind() { echo hdd; }
  [ "$(node_labels worker)" = "homelab/role=worker,homelab/disk=hdd" ]
  disk_kind() { return 0; }
  [ "$(node_labels master)" = "homelab/role=master" ]
}
@test "node_labels adds the storage label only when the data partition is mounted" {
  disk_kind() { echo ssd; }
  has_data_mount() { return 0; }
  [ "$(node_labels master)" = "homelab/role=master,homelab/disk=ssd,homelab/storage=media" ]
  has_data_mount() { return 1; }
  [ "$(node_labels master)" = "homelab/role=master,homelab/disk=ssd" ]
}
@test "node_labels appends extra labels" {
  disk_kind() { echo ssd; }
  has_data_mount() { return 1; }
  [ "$(node_labels worker team=a)" = "homelab/role=worker,homelab/disk=ssd,team=a" ]
}
@test "has_data_mount follows the real mount state of DATA_MOUNT" {
  DATA_MOUNT=/proc;  has_data_mount          # /proc is a mount point
  DATA_MOUNT="$TMP"; ! has_data_mount        # a plain temp dir is not
}
