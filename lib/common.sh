#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHANGED is read by the scripts that source this file
# Shared helpers. Source only (no side effects besides function definitions).

LOG_FILE="${LOG_FILE:-/var/log/k8s-homelab.log}"
CHANGED=0   # set by install_file / install_rendered; read by the scripts that call them

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() { # level color msg
  local line; line="[$(_ts)] [$1] $3"
  printf '%b%s%b\n' "$2" "$line" $'\e[0m' >&2
  { printf '%s\n' "$line" >>"$LOG_FILE"; } 2>/dev/null || true
}
log()  { _log INFO  $'\e[32m' "$*"; }
warn() { _log WARN  $'\e[33m' "$*"; }
err()  { _log ERROR $'\e[31m' "$*"; }
step() { _log STEP  $'\e[1;36m' "== $* =="; }
die()  { err "$*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- prompts: always read from the terminal so they work under `curl | sudo bash` ----
_tty() { [[ -r /dev/tty ]] && echo /dev/tty || echo /dev/stdin; }

# prompt VAR "Question" [default]   -> sets VAR (env var of same name wins, no prompt)
prompt() {
  local var="$1" q="$2" def="${3:-}" ans
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ "${NONINTERACTIVE:-0}" == 1 ]]; then
    [[ -n "$def" ]] || die "$var is required (non-interactive mode)."
    printf -v "$var" '%s' "$def"; return 0
  fi
  read -r -p "$q${def:+ [$def]}: " ans <"$(_tty)"
  printf -v "$var" '%s' "${ans:-$def}"
  [[ -n "${!var}" ]] || die "$var cannot be empty."
}
# ask_default VAR "Question"  -> asks even though VAR has a built-in default; skipped when the
# answer is already saved in config.env or in non-interactive mode. Saves the answer.
ask_default() {
  local var="$1" q="$2" ans
  if [[ "${NONINTERACTIVE:-0}" == 1 ]] || grep -qsE "^${var}=" "$CONFIG_FILE"; then return 0; fi
  read -r -p "$q [${!var:-}]: " ans <"$(_tty)"
  printf -v "$var" '%s' "${ans:-${!var:-}}"
  [[ -n "${!var}" ]] || die "$var cannot be empty."
  config_set "$var" "${!var}"
}
# prompt_secret VAR "Question"  (never echoed, never written to disk/log)
prompt_secret() {
  local var="$1" q="$2" ans
  if [[ -n "${!var:-}" ]]; then return 0; fi
  read -r -s -p "$q: " ans <"$(_tty)"; echo >&2
  printf -v "$var" '%s' "$ans"
}
# confirm "Question" [default y|n] -> returns 0 for yes
confirm() {
  local q="$1" def="${2:-n}" ans hint="[y/N]"
  [[ "$def" == y ]] && hint="[Y/n]"
  if [[ "${ASSUME_YES:-0}" == 1 ]]; then return 0; fi
  if [[ "${NONINTERACTIVE:-0}" == 1 ]]; then [[ "$def" == y ]]; return; fi
  read -r -p "$q $hint " ans <"$(_tty)"
  ans="${ans:-$def}"; [[ "${ans,,}" == y* ]]
}

# ---- persisted answers (config.env is gitignored) ----
config_set() { # KEY VALUE
  local k="$1" v="$2" f="$CONFIG_FILE"
  touch "$f"; chmod 600 "$f"
  if grep -qE "^${k}=" "$f"; then sed -i "s|^${k}=.*|${k}=${v}|" "$f"; else echo "${k}=${v}" >>"$f"; fi
}

# ---- validation ----
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && IFS=. read -r a b c d <<<"$1" && ((a<256&&b<256&&c<256&&d<256)); }
is_host_or_ip() { is_ipv4 "$1" || [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }

# ---- system helpers ----
apt_update_once() { [[ -n "${_APT_UPDATED:-}" ]] || { DEBIAN_FRONTEND=noninteractive apt-get update -qq; _APT_UPDATED=1; }; }
apt_install() { apt_update_once; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"; }

# apt_version_for PKG PREFIX -> full apt version string starting with PREFIX
apt_version_for() {
  local v; v="$(apt-cache madison "$1" | awk '{print $3}' | grep -E "^${2//./\\.}" | head -n1)"
  [[ -n "$v" ]] || die "No apt version of '$1' matches '$2'. Check versions.env (see: apt-cache madison $1)."
  echo "$v"
}

# write_file PATH [MODE] <stdin>  -> copies stdin to PATH; returns 1 if PATH already had that content
write_file() {
  local path="$1" mode="${2:-644}" tmp; tmp="$(mktemp)"
  cat >"$tmp"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 1; fi
  install -m "$mode" "$tmp" "$path"; rm -f "$tmp"; return 0
}

# ---- templates/ helpers. After each call, $CHANGED is 1 if the destination file changed. ----
# install_file TEMPLATE DEST [MODE]      copy a static file from templates/
# render TEMPLATE                        print a template with ${VARS} replaced (vars must be exported)
# install_rendered TEMPLATE DEST [MODE]  render, then write to DEST
install_file()     { if write_file "$2" "${3:-644}" <"$REPO_ROOT/templates/$1"; then CHANGED=1; else CHANGED=0; fi; }
render()           { envsubst <"$REPO_ROOT/templates/$1"; }
install_rendered() { if render "$1" | write_file "$2" "${3:-644}"; then CHANGED=1; else CHANGED=0; fi; }

# ---- apt helpers ----
installed_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo "-"; }

# add_apt_repo NAME KEY_URL "URI SUITE [COMPONENTS]"   (key refreshed only if missing)
add_apt_repo() {
  local name="$1" key_url="$2" line="$3" keyring="/etc/apt/keyrings/$1.gpg"
  install -d -m 0755 /etc/apt/keyrings
  [[ -s "$keyring" ]] || curl -fsSL "$key_url" | gpg --dearmor --yes -o "$keyring"
  if echo "deb [signed-by=$keyring] $line" | write_file "/etc/apt/sources.list.d/$name.list"; then _APT_UPDATED=""; fi
  apt_update_once
}

# install_pinned PKG VERSION_PREFIX   -> install that exact version and hold it
install_pinned() {
  local pkg="$1" want
  want="$(apt_version_for "$pkg" "$2")"
  if [[ "$(installed_version "$pkg")" != "$want" ]]; then
    apt-mark unhold "$pkg" >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --allow-downgrades "$pkg=$want"
  fi
  apt-mark hold "$pkg" >/dev/null
  log "$pkg $want installed (held)"
}

# ensure_hosts_entry IP NAME  (replaces any previous line for NAME; HOSTS_FILE is overridable for tests)
ensure_hosts_entry() {
  local ip="$1" name="$2" file="${HOSTS_FILE:-/etc/hosts}"
  sed -i "/[[:space:]]${name//./\\.}\([[:space:]]\|\$\)/d" "$file"
  echo "$ip $name # k8s-homelab" >>"$file"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; *) die "Unsupported arch $(uname -m)";;
  esac; export ARCH
}

# disk_kind -> ssd|hdd for the device backing /
disk_kind() {
  local src dev rot
  src="$(findmnt -no SOURCE / | sed 's/\[.*//')"
  dev="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)"; dev="${dev:-$(basename "$src")}"
  rot="$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null || echo 0)"
  [[ "$rot" == 1 ]] && echo hdd || echo ssd
}

# retry N SLEEP cmd...
retry() { local n="$1" s="$2" i; shift 2; for ((i=1;i<=n;i++)); do "$@" && return 0; sleep "$s"; done; return 1; }

# ---- GitOps helpers: chart version pinned in the app's application.yaml ----
# app_chart_version gitops/apps/platform/cilium  -> targetRevision of the chart source
app_chart_version() {
  awk '/^[[:space:]]*-?[[:space:]]*chart:/ {f=1; next}
       f && /targetRevision:/ {gsub(/["'\'']/,"",$2); print $2; exit}' "$REPO_ROOT/$1/application.yaml" 2>/dev/null
}
