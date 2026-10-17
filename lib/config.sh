#!/usr/bin/env bash
# Loads versions.env, defaults and saved answers (config.env). Source after common.sh.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config.env}"
export REPO_ROOT CONFIG_FILE

# env vars set by the caller win over everything: remember them, source files, restore
_preset="$(env | grep -E '^(ROLE|MASTER_IP|NODE_IP|NODE_NAME|CONTROL_PLANE_ENDPOINT|POD_CIDR|SERVICE_CIDR|GITOPS_REPO_URL|GITOPS_REVISION|DATA_MOUNT|DATA_PUID|DATA_PGID|ENABLE_SECRETS_ENCRYPTION|ENABLE_FIREWALL|JOIN_TOKEN|CA_HASH|NETBIRD_SETUP_KEY|NONINTERACTIVE|ASSUME_YES)=' || true)"

# shellcheck disable=SC1091
source "$REPO_ROOT/versions.env"
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
[[ -n "$_preset" ]] && while IFS='=' read -r k v; do export "$k=$v"; done <<<"$_preset"
unset _preset

: "${CONTROL_PLANE_ENDPOINT:=k8s-api.homelab.chiragsoni.org}"
: "${POD_CIDR:=10.244.0.0/16}"
: "${SERVICE_CIDR:=10.96.0.0/12}"
: "${GITOPS_REVISION:=main}"
: "${DATA_MOUNT:=/DATA}"
: "${ENABLE_SECRETS_ENCRYPTION:=yes}"
: "${ENABLE_FIREWALL:=no}"
K8S_MINOR="${K8S_VERSION%.*}"
export CONTROL_PLANE_ENDPOINT POD_CIDR SERVICE_CIDR GITOPS_REVISION DATA_MOUNT \
       ENABLE_SECRETS_ENCRYPTION ENABLE_FIREWALL K8S_MINOR K8S_VERSION CONTAINERD_VERSION HELM_VERSION NETBIRD_VERSION
