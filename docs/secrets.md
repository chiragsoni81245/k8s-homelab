# Secrets: Proton Pass operator

Secrets come from Proton Pass via the [proton-secrets-operator](https://github.com/chiragsoni81245/proton-secrets-operator)
(unofficial). Git only holds *references* (`pass://vault/item/field`); values never touch git.

| Piece | Where |
|-------|-------|
| Operator + CRD (Helm chart from the operator repo) | `gitops/apps/platform/proton-secrets-operator/` (wave 3) |
| `ProtonSecret` objects (one manifest per Secret) | in the `manifests/` of the app that uses the Secret, e.g. `platform/netbird-router/manifests/protonsecret-netbird-setup-key.yaml` |
| Bootstrap PAT Secret | `sudo tools/create-proton-pat-secret.sh` -> `proton-secrets-system/proton-pat` |

## Bootstrap (once)
1. In Proton Pass create a dedicated vault (e.g. `homelab`) and a **read-only (viewer)** personal access token scoped to it,
   (`pass-cli pat create`, see the pass-cli docs; PATs have an expiry date).
2. `sudo tools/create-proton-pat-secret.sh` (token is prompted, never stored). When Proton starts rejecting the token
   (e.g. it expired) the `ProtonAuthFailing` alert fires.
3. Check: `kubectl get protonsecret -A` -> every one `Ready=True` (the first is the NetBird router's setup key).

## Using it
Add a `ProtonSecret` to the app's `manifests/` (its Application needs `SkipDryRunOnMissingResource=true` and a sync wave after the operator's 3). It syncs on change, every `refreshInterval`, on manual edits of the Secret
(reverted) and when you set the annotation `proton-secrets.io/force-sync` to a new value. `rolloutTargets` restarts
workloads that only read the Secret at start (e.g. Grafana).

## Notes
- Argo CD only prunes resources it tracks; the operator-created Secrets are not in git, so prune/selfHeal leave them alone.
- If Proton is unreachable or the PAT expired, existing Secrets stay as they are; the ProtonSecret goes `Ready=False`.
- Rotate the PAT: create a new one, re-run `tools/create-proton-pat-secret.sh` (no git change needed).
- etcd encryption at rest is enabled by default by `scripts/50-master-init.sh` (`ENABLE_SECRETS_ENCRYPTION`).
- Migrating the hand-made secrets (`create-grafana-secret.sh`, `create-cloudflare-secret.sh`, `create-samba-user.sh`) to
  `ProtonSecret`s is a later step; the scripts stay until each Secret is verified.
