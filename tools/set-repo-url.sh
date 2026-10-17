#!/usr/bin/env bash
# Rewrite the GitOps repo URL / branch in every file under gitops/ (lines marked '# homelab-repo').
# Usage: tools/set-repo-url.sh <repo-url> [branch]   -> then commit & push!
set -euo pipefail
url="${1:?usage: $0 <repo-url> [branch]}"; rev="${2:-main}"
cd "$(dirname "$0")/../gitops"
grep -rl '# homelab-repo' . | while read -r f; do
  sed -i -E "/# homelab-repo/ s#(repoURL:[[:space:]]*)[^[:space:]]+#\1${url}#" "$f"
  sed -i -E "/# homelab-revision/ s#(targetRevision:[[:space:]]*)[^[:space:]]+#\1${rev}#" "$f"
done
echo "Updated gitops/ -> $url @ $rev. Now: git add -A && git commit && git push"
