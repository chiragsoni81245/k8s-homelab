# Troubleshooting

- Logs: `/var/log/k8s-homelab.log`. Everything is idempotent - fix the cause and re-run `sudo ./setup.sh`.
- Node NotReady after init: expected until Cilium is installed (scripts/55). `kubectl -n kube-system get pods`.
- `k8s-api...` does not resolve on another machine: add a DNS/router/NetBird DNS record -> master IP.
- Worker join fails: token expired (`kubeadm token create --print-join-command` on master), `nc -vz <master> 6443`, clock skew (chrony).
- LB IP unreachable: pool excluded from router DHCP? `kubectl get ciliumloadbalancerippool`, `kubectl -n envoy-gateway-system get svc`,
  `kubectl get ciliuml2announcementpolicy`; interface regex in `cilium/manifests/ciliuml2announcementpolicy-homelab.yaml` must match your NIC name (`ip -br link`).
- Argo app stuck: `kubectl -n argocd get applications`, `argocd` UI; wrong repo URL -> `tools/set-repo-url.sh`, push.
- Rebuild a node: reinstall Ubuntu, run the curl one-liner again; `/DATA` is only mounted, never formatted.
- Rejoin a worker: on the node `sudo kubeadm reset -f`, on the master `kubectl delete node <name>`, then run setup.sh again.
