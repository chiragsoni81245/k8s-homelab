#!/usr/bin/env bash
# Run on the master after a worker joins: adds the node-role.kubernetes.io/worker label
# (kubelets are not allowed to set node-role labels themselves).  Usage: sudo tools/label-nodes.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/config.sh"
require_root
source "$ROOT/scripts/65-label-nodes.sh"
