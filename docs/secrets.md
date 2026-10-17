# Secrets (planned: custom Proton Pass syncer)

Nothing is installed for this yet. Suggested shape (pass-cli: `pass://vault/item/field` references; non-interactive auth with a
Personal Access Token via `PROTON_PASS_PERSONAL_ACCESS_TOKEN`, 2h sessions -> log in on every run):

1. Declarative mapping in git, values never in git: `{secretName, namespace, data: {KEY: pass://vault/item/field}}`.
2. A CronJob (later a controller/CRD, chart in `gitops/charts/`) logs in with the PAT, resolves the references and creates native Secrets.
3. The PAT is the single bootstrap secret (`kubectl create secret`), scoped read-only to one dedicated vault. Rotate by regenerating.
4. Argo prune/selfHeal deletes objects it does not track - label syncer-created Secrets and exclude them (`resource.exclusions` / IgnoreExtraneous).
5. etcd encryption at rest is enabled by default by `scripts/50-master-init.sh` (`ENABLE_SECRETS_ENCRYPTION`).
