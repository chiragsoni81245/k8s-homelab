# GitOps: adding an app

Argo CD watches `gitops/apps` through the `root` app-of-apps (`gitops/bootstrap/root-app.yaml`, include `**/application.yaml`).

1. `mkdir gitops/apps/<category>/<name>` (categories are free-form: `platform`, `observability`, `workloads`, ...)
2. Add `application.yaml` - a full Argo `Application` (copy `apps/platform/envoy-gateway/application.yaml`).
   Pin the upstream chart in `targetRevision`; take values from `values.yaml` via the `$values` ref source.
3. Add `values.yaml`; plain manifests go in `manifests/`, **one resource per file** named `<kind>-<name>.yaml`
   (e.g. `httproute-grafana.yaml`), picked up by a source with `path: gitops/apps/<category>/<name>/manifests` - no include list.
   `tests/unit/gitops.bats` enforces the layout.
4. `git push` - Argo creates the Application; control sync/prune/health per app in the UI.

Notes
- Repo URL / branch lines are tagged `# homelab-repo` / `# homelab-revision`; `tools/set-repo-url.sh <url> [branch]` rewrites them (then commit & push).
- Bootstrap vs GitOps: `setup.sh` installs only Cilium and Argo CD with helm, from the same `values.yaml` and chart version Argo then uses - no drift.
- Upgrade an add-on: bump `targetRevision`, push. Host components: edit `versions.env`, run `sudo ./update.sh <component>`.
- Private repo: use an ssh URL; setup.sh asks for a **read-only deploy key** file and creates the Argo repo Secret (never stored in git).
- CoreDNS is owned by kubeadm; do not manage it with Argo.
