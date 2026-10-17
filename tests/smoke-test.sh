#!/usr/bin/env bash
# Run on the master after setup: nodes Ready, Cilium healthy, Argo apps synced, and a real
# request through Envoy Gateway on a Cilium LoadBalancer IP.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
ns=smoke-test; fail=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }

kubectl get nodes --no-headers | awk '$2!="Ready"{exit 1}' && ok "all nodes Ready" || bad "a node is not Ready"
kubectl -n kube-system rollout status ds/cilium --timeout=120s >/dev/null && ok "cilium daemonset ready" || bad "cilium not ready"
if [[ -z "$(kubectl -n argocd get applications --no-headers 2>/dev/null | awk '$2!="Synced"||$3!="Healthy"')" ]]; then ok "argo apps Synced/Healthy"; else bad "argo apps not all Synced/Healthy"; kubectl -n argocd get applications; fi

LB_IP="$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=homelab -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
[[ -n "$LB_IP" ]] && ok "gateway LoadBalancer IP: $LB_IP" || bad "gateway has no LoadBalancer IP"

kubectl create ns $ns --dry-run=client -o yaml | kubectl apply -f - >/dev/null
trap 'kubectl delete ns $ns --wait=false >/dev/null 2>&1 || true' EXIT
kubectl -n $ns create deployment web --image=nginx:alpine --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $ns expose deployment web --port 80 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $ns apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: web}
spec:
  parentRefs: [{name: homelab, namespace: envoy-gateway-system}]
  hostnames: [smoke.test]
  rules: [{backendRefs: [{name: web, port: 80}]}]
YAML
kubectl -n $ns rollout status deploy/web --timeout=180s >/dev/null && ok "test pod running" || bad "test pod not running"
if [[ -n "$LB_IP" ]]; then
  sleep 5
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: smoke.test' "http://$LB_IP/" || true)"
  [[ "$code" == 200 ]] && ok "HTTP 200 via $LB_IP (from this node; also try from another LAN machine)" || bad "HTTP $code via $LB_IP"
fi
exit $fail
