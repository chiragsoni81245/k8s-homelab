#!/usr/bin/env bats
# NIC selection helpers (lib/network.sh).
load helpers
setup() {
  setup_env
  # shellcheck disable=SC1091
  source "$ROOT/lib/network.sh"
}
teardown() { teardown_env; }

@test "filter keeps physical-looking NICs" {
  run filter_candidate_nics <<<$'enp0s3 10.0.2.15/24\nenp0s8 192.168.56.10/24\neth0 192.168.0.160/24'
  [ "${#lines[@]}" -eq 3 ]
}
@test "filter drops loopback, docker, cilium, veth, VPN and bridge interfaces" {
  run filter_candidate_nics <<<$'lo 127.0.0.1/8\ndocker0 172.17.0.1/16\ncilium_host 10.244.0.1/32\nlxc1234 10.244.0.5/32\nveth9 1.2.3.4/24\nwt0 100.64.0.1/16\nvirbr0 192.168.122.1/24\nbr-abc 172.18.0.1/16\nenp0s8 192.168.56.10/24'
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "enp0s8 192.168.56.10/24" ]
}
@test "filter on empty input produces nothing and succeeds" {
  run filter_candidate_nics <<<""
  [ "$status" -eq 0 ]
}

# choose_nic with a fake `ip` command (non-interactive => picks the default-route NIC)
fake_ip() { printf '2: enp0s3 inet 10.0.2.15/24 brd x scope global enp0s3\n3: enp0s8 inet 192.168.56.10/24 brd x scope global enp0s8\n'; }

@test "choose_nic offers all NICs and defaults to the default-route one" {
  ip() { fake_ip; }
  DEFAULT_IF=enp0s3
  choose_nic 2>"$TMP/menu"
  [ "$NODE_IF_CHOICE" = enp0s3 ]
  [ "$NODE_IP_DEFAULT" = 10.0.2.15 ]
  grep -q 'enp0s8' "$TMP/menu"
  grep -q '(default route)' "$TMP/menu"
}
@test "choose_nic picks the only NIC without asking" {
  ip() { printf '2: eth0 inet 192.168.0.160/24 brd x scope global eth0\n'; }
  DEFAULT_IF=eth0
  choose_nic 2>"$TMP/menu"
  [ "$NODE_IF_CHOICE" = eth0 ]
  [ ! -s "$TMP/menu" ]
}
@test "choose_nic fails when no usable NIC exists" {
  ip() { printf '1: lo inet 127.0.0.1/8 scope host lo\n'; }
  DEFAULT_IF=lo
  run choose_nic
  [ "$status" -ne 0 ]
}
