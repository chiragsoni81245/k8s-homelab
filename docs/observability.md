# Observability (VictoriaMetrics)

App: `gitops/apps/observability/victoria-metrics/` (chart `victoria-metrics-k8s-stack`, namespace `monitoring`).

| File | What |
|---|---|
| `values.yaml` | VMCluster, VictoriaLogs (vlsingle), vmagent, vmalert, Alertmanager, Grafana, node-exporter, kube-state-metrics; what is (not) scraped |
| `manifests/vm*scrape-*.yaml` | extra targets: Cilium agent + operator, Envoy proxies + Envoy Gateway controller |
| `manifests/vmrule-homelab-addons.yaml` | extra alerts: backend 5xx rate, gateway certificate expiry, Cilium drop rate |
| `manifests/httproute-*.yaml` | `grafana.` and `alertmanager.chiragsoni.org` through the homelab Gateway |
| `dashboards/*.json` | own Grafana dashboards (AMD GPU) |

## Layout
```
Dell (master)                          Asus (worker)
vmstorage-vm-0  5Gi local-path         vmstorage-vm-1  5Gi local-path
node-exporter                          node-exporter
+ operator, vminsert, vmselect, vmagent, vmalert, alertmanager, kube-state-metrics, grafana: wherever they fit
```
- `replicationFactor: 2`: every sample is stored on both vmstorage pods; one node down = no data loss, queries still work
  if vminsert/vmselect are on the surviving node (they're single replicas; Kubernetes reschedules them after ~5 min).
- Data lives in `/var/lib/local-path` on each node's **root disk** (not `/DATA`). The 5Gi is nominal, not enforced;
  `storage.minFreeDiskSpaceBytes=1GB` switches vmstorage to read-only before the disk fills up.
- Retention **7 days**. Check real usage: `sudo du -sh /var/lib/local-path/*vmstorage*` on each node.

## First install
1. Create the Grafana admin secret (never in git) with the helper; an empty password prompt generates one and shows it once:
   ```bash
   sudo tools/create-grafana-secret.sh
   ```
   (Manual equivalent: `kubectl create namespace monitoring`, then `kubectl -n monitoring create secret generic grafana-admin
   --from-literal=admin-user=admin --from-literal=admin-password=<password>`.)
2. Push. Argo syncs the `cilium` app (metrics port on; the agents restart one node at a time) and creates `victoria-metrics`.
3. Point `grafana.` and `alertmanager.chiragsoni.org` at `192.168.0.200` (like Jellyfin, see [networking](networking.md)).
4. Check:
   ```bash
   kubectl -n monitoring get vmcluster,vmagent,vmalert,vmalertmanager   # STATUS operational
   kubectl -n monitoring get pods -o wide                                # vmstorage-vm-0/1 on different nodes
   ```
   Targets: `kubectl -n monitoring port-forward svc/vmagent-vm 8429` -> http://localhost:8429/targets (all `up`).

## URLs
- **vmui** (queries, also shows vmalert's alerts/rules): not exposed. `kubectl -n monitoring port-forward svc/vmselect-vm 8481`
  -> http://localhost:8481/select/0/vmui/ (or query in Grafana Explore)
- **Grafana**: https://grafana.chiragsoni.org (dashboards synced at deploy time: Kubernetes views, node-exporter, VM components,
  Cilium agent/operator, Envoy Gateway/proxy/clusters)
- **Alertmanager**: https://alertmanager.chiragsoni.org
- Alertmanager has **no login**: keep it LAN/NetBird-only (no inbound ports are opened, see networking).

## What is scraped
node-exporter, kubelet, cAdvisor, kube-state-metrics, kube-apiserver, CoreDNS, the VM components, Grafana, Cilium (agent `:9962`,
operator `:9963`), Envoy proxies (`:19001/stats/prometheus`) and the Envoy Gateway controller (`:19001/metrics`).
**GPU (Dell, AMD):** node-exporter's `drm` collector (`--collector.drm` in `values.yaml`) adds `node_drm_gpu_busy_percent`,
`node_drm_memory_vram_{used,size}_bytes` and GTT usage per `card`; temperature and power come from `hwmon` (`chip_name="amdgpu"`).
Grafana dashboard **AMD GPU** (`dashboards/amd-gpu.json`, fetched by the sync-job from this repo's public `main` branch).
The card with ~6 GB VRAM is the dedicated Navi 10 (PCI `03:00.0`); the other is the Renoir iGPU (`07:00.0`).
Not scraped: etcd, kube-scheduler, kube-controller-manager (bound to `127.0.0.1` by kubeadm) and kube-proxy (replaced by Cilium).

## Logs (VictoriaLogs + Filebeat)
- **Filebeat** (`gitops/apps/observability/filebeat`, DaemonSet, one per node) tails `/var/log/containers/*.log`, adds
  Kubernetes metadata and ships to VictoriaLogs' Elasticsearch-compatible endpoint (`vlsingle-vm:9428/insert/elasticsearch/`).
- **VictoriaLogs** (`vlsingle` in `values.yaml`): 7 days, 10Gi `local-path` (capped at 9GiB on disk). One stream per container
  (`kubernetes.namespace`, `kubernetes.pod.name`, `kubernetes.container.name`).
- **Query** in Grafana -> Explore -> data source "VictoriaLogs (DS)" (plugin installed by the chart), LogsQL e.g.
  `{kubernetes.namespace="jellyfin"} error`, or its own UI: `kubectl -n monitoring port-forward svc/vlsingle-vm 9428`
  -> http://localhost:9428/select/vmui/
- Only container logs (stdout/stderr); host logs (journald, kubelet) are not collected.

## Alerts
Default rules from the chart (Kubernetes, node, VM components, `TargetDown`, and an always-firing `Watchdog`) plus `manifests/vmrule-homelab-addons.yaml`.
Alertmanager has **no receiver yet**: alerts show in its UI only. Add one under `alertmanager.config` in `values.yaml`.

## Add a scrape target
Expose metrics on a named port, then add a `VMServiceScrape` (via a Service) or `VMPodScrape` (pods directly) as a new file `manifests/<kind>-<name>.yaml`,
with `namespaceSelector` + `selector` matching the app and a `relabelConfigs` entry setting `job`. Copy an existing one.
