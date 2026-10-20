# k8s-homelab

Turn a bare **Ubuntu Server** laptop into a Kubernetes **master** or **worker** (kubeadm + containerd + Cilium + Envoy Gateway, GitOps with Argo CD).

```bash
# on a fresh Ubuntu Server (as a sudo user)
curl -fsSL https://raw.githubusercontent.com/chiragsoni81245/k8s-homelab/main/install.sh | sudo bash
```
It asks **master or worker**, then:

| Step | What |
|---|---|
| server mode | Wi-Fi/Bluetooth off, lid/suspend ignored, console blanking, no auto-reboot |
| host prep | swap off, kernel modules/sysctl, chrony, containerd (pinned), kubeadm/kubelet/kubectl (pinned, held) |
| **master** | `kubeadm init` with `--control-plane-endpoint k8s-api.homelab.chiragsoni.org`, schedulable, Cilium (kube-proxy replacement, LB-IPAM + L2), Argo CD, root app-of-apps -> Envoy Gateway, local storage |
| **worker** | optional `/DATA` mount (never formatted), asks master IP + token + CA hash, `kubeadm join`, node labels |
| optional | NetBird agent (host-level), ufw |

Prompts you will see: role, node IP (confirm), hostname, control-plane endpoint, GitOps repo URL/branch, (ssh repo: deploy-key path), secrets encryption, NetBird setup key; worker: master IP, token, CA hash, `/DATA` partition.
Answers are saved in the gitignored `config.env`. No secrets are stored in this repo.

## Layout
```
install.sh  setup.sh  update.sh  versions.env  config.env.example
lib/        common.sh config.sh
scripts/    00-preflight 05-identity 10-server-mode 15-firewall 20-system-prep 30-container-runtime 40-kube-packages
            50-master-init 55-master-bootstrap 65-label-nodes | 35-data-mount 60-worker-join | 70-netbird
gitops/     bootstrap/ (root app, projects)   apps/<category>/<name>/{application.yaml,values.yaml,manifests/<kind>-<name>.yaml}   charts/
templates/  system/ (logind, sysctl, ...)  kubernetes/ (kubeadm init/join, encryption)  <- config files, edit these
tools/      set-repo-url.sh        tests/ smoke-test.sh        docs/
```

## Editing the scripts
- Each `scripts/NN-*.sh` starts with a header (what it does, which templates it uses), then small named functions, and ends with a short flow of calls - read the last lines first.
- Config files live in `templates/` as plain files; `${VARS}` are filled in by `render` (`lib/common.sh`). Static ones are copied with `install_file`.
- Shared helpers in `lib/common.sh`: `prompt`/`ask_default`/`confirm`, `install_file`/`install_rendered`, `add_apt_repo`, `install_pinned`, `config_set`.

## Day 2
- Status / newest releases: `sudo ./update.sh status` · `./update.sh check`
- Host upgrades: edit `versions.env`, then `sudo ./update.sh k8s|containerd|helm|netbird|os|all` (`--dry-run` first).
- Add-on upgrades & new apps: edit `gitops/`, push - see [docs/gitops.md](docs/gitops.md).
- Tests: `tests/run.sh` (lint + unit tests, no root/cluster; needs `bats shellcheck python3-yaml gettext-base jq`; also runs in GitHub Actions). On a live master: `sudo tests/smoke-test.sh`.
- Docs: [networking](docs/networking.md) · [storage](docs/storage.md) · [TLS](docs/tls.md) · [secrets](docs/secrets.md) · [observability](docs/observability.md) · [troubleshooting](docs/troubleshooting.md)

Pinned versions (2026-10-17): Kubernetes 1.36.5, containerd 2.4.2, Helm 4.3.1, Cilium 1.20.3, Argo CD chart 10.10.5, Envoy Gateway v1.9.2, cert-manager v1.21.2, victoria-metrics-k8s-stack 0.96.0, NetBird 0.81.2.
