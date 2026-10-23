#!/usr/bin/env bash
# Run on the master: refreshes this node's detected labels and adds node-role.kubernetes.io/worker to workers
# (kubelets are not allowed to set node-role labels themselves).  Usage: sudo tools/label-nodes.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/config.sh"
require_root
NODE_NAME="${NODE_NAME:-$(hostname)}"; NODE_NAME="${NODE_NAME,,}"
source "$ROOT/scripts/65-label-nodes.sh"
