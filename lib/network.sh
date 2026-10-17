#!/usr/bin/env bash
# shellcheck disable=SC2034  # NODE_IF_CHOICE / NODE_IP_DEFAULT are read by scripts/00-preflight.sh
# NIC discovery/selection helpers. Source after lib/common.sh.

# Keep real LAN-style NICs: drop loopback and virtual interfaces (docker, cilium, veth, bridges, VPN...).
# stdin: lines like "enp0s3 10.0.2.15/24"  ->  stdout: the lines worth offering.
filter_candidate_nics() { grep -vE '^(lo|docker|cni|cilium|lxc|veth|flannel|wt|virbr|br-|kube|tun|tap)' || true; }

list_candidate_nics() { ip -4 -o addr show scope global | awk '{print $2, $4}' | filter_candidate_nics; }

# Let the user choose which NIC/IP this node uses (only asked when there is more than one).
choose_nic() {  # sets NODE_IF_CHOICE and NODE_IP_DEFAULT
  local -a options; local i default_idx=1 pick
  mapfile -t options < <(list_candidate_nics)
  (( ${#options[@]} > 0 )) || die "No usable network interface with an IPv4 address."

  if (( ${#options[@]} > 1 )); then
    for i in "${!options[@]}"; do
      [[ "${options[$i]%% *}" == "$DEFAULT_IF" ]] && default_idx=$((i+1))
    done
    echo >&2; echo "Network interfaces found:" >&2
    for i in "${!options[@]}"; do
      printf '  %d) %-10s %s%s\n' $((i+1)) "${options[$i]%% *}" "${options[$i]#* }" \
        "$([[ $((i+1)) == "$default_idx" ]] && echo '   (default route)')" >&2
    done
    pick=1
    if [[ "${NONINTERACTIVE:-0}" == 1 ]]; then pick=$default_idx
    else read -r -p "Which one is this node's cluster/LAN interface? [$default_idx]: " pick <"$(_tty)"; pick="${pick:-$default_idx}"; fi
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#options[@]} )) || die "Invalid choice: $pick"
    options=("${options[$((pick-1))]}")
  fi
  NODE_IF_CHOICE="${options[0]%% *}"
  NODE_IP_DEFAULT="$(cut -d/ -f1 <<<"${options[0]#* }")"
}
