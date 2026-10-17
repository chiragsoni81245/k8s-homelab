#!/usr/bin/env bash
# Fresh-install entry point:
#   curl -fsSL https://raw.githubusercontent.com/chiragsoni81245/k8s-homelab/main/install.sh | sudo bash
# Override with: HOMELAB_REPO=<url> HOMELAB_BRANCH=<branch> HOMELAB_DIR=<dir>
set -euo pipefail

REPO="${HOMELAB_REPO:-https://github.com/chiragsoni81245/k8s-homelab.git}"
BRANCH="${HOMELAB_BRANCH:-main}"
DIR="${HOMELAB_DIR:-/opt/k8s-homelab}"

[[ $EUID -eq 0 ]] || { echo "Run as root: curl ... | sudo bash" >&2; exit 1; }
[[ -r /dev/tty ]] || echo "WARNING: no TTY; prompts will need env vars (NONINTERACTIVE=1 ROLE=...)." >&2

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates

if [[ -d "$DIR/.git" ]]; then
  git -C "$DIR" fetch --quiet origin "$BRANCH"
  git -C "$DIR" checkout --quiet "$BRANCH"
  git -C "$DIR" merge --ff-only --quiet "origin/$BRANCH"
else
  git clone --quiet --branch "$BRANCH" "$REPO" "$DIR"
fi

# The clone is created by root (via sudo); let the invoking user work in it too. git otherwise refuses
# ("dubious ownership") when the owner differs from the user running it.
git config --system --get-all safe.directory | grep -qxF "$DIR" || git config --system --add safe.directory "$DIR"
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$DIR"
fi

cd "$DIR"
# stdin may be the curl pipe; prompts read /dev/tty themselves (lib/common.sh)
exec ./setup.sh "$@"
