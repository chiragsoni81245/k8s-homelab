# Networking

```
Internet - ISP router 192.168.1.0/24 - TP-Link (WAN) - TP-Link LAN 192.168.0.0/24
                                                         |- master node   e.g. 192.168.0.160
                                                         |- worker node   e.g. 192.168.0.161
                                                         '- LB pool       192.168.0.200-220
```
- Nodes use **DHCP reservations** on the TP-Link. Exclude `.200-.220` from its DHCP pool.
- No inbound ports are opened on the ISP router. Remote access = NetBird (outbound only).
- Pod CIDR `10.244.0.0/16`, service CIDR `10.96.0.0/12`, NetBird `100.64.0.0/10` - no overlap with the LANs.

## Control-plane endpoint
Everything uses `k8s-api.homelab.chiragsoni.org`, never the raw IP. `setup.sh` adds it to `/etc/hosts` on each node.
For other machines (laptop on LAN / over NetBird) create an A record -> `192.168.0.160` in your DNS, or a
TP-Link/NetBird DNS override. To move the API to another node later, change that one record.
`k8sServiceHost` in `gitops/apps/platform/cilium/values.yaml` must be the same name (setup.sh checks).

## LoadBalancer IPs (Cilium LB-IPAM + L2 announcements)
`gitops/apps/platform/cilium/manifests/ciliumloadbalancerippool-homelab.yaml` gives Cilium the range. A Service of `type: LoadBalancer` gets an IP from it;
one node answers ARP for that IP (leader election), so any LAN device can reach it. Envoy Gateway's Service is pinned to
`192.168.0.200` (annotation `lbipam.cilium.io/ips` in `envoy-gateway/manifests/envoyproxy-homelab.yaml`). Point DNS names (`*.home...`) at that IP and route
with `HTTPRoute`s. Non-HTTP services get their own fixed IP from the pool instead: Samba is `192.168.0.201`
(`workloads/samba/manifests/service-samba.yaml`).

## NetBird
Two NetBird peers run on the node, with different jobs:

| Peer | Installed by | Job |
|---|---|---|
| host agent (node name) | `scripts/70-netbird.sh`, on the node OS | SSH / `kubectl` to the node over its NetBird IP; works even if Kubernetes is down. **Not** a routing peer. |
| `k8s-router` (pod) | Argo app `platform/netbird-router` | routing peer for the LoadBalancer IPs (`.200` Envoy Gateway, `.201` Samba, ...) |

Why the LB IPs need a pod: the node itself announces them (Cilium L2), and a node can't ARP-resolve an IP it announces,
so the host agent can't forward to them. Inside a pod, Cilium treats an LB IP as a service address and hands the
packet straight to Envoy/Samba - no ARP:
```
laptop -WireGuard-> k8s-router pod (wt0) -masquerade-> pod eth0 -Cilium service LB-> Envoy / Samba pod
```
Cilium stays off the host's `wt0` (`devices: "en+,eth+"` in the Cilium values): with its eBPF on `wt0`, LB-IP traffic
was taken before NetBird's forward ACL and silently lost.

### NetBird console (once)
1. **Groups**: `k8s-router` (the pod) and one for your own devices, e.g. `admins`.
2. **Setup key** for the pod: reusable, **ephemeral**, auto-assigned group `k8s-router`. Ephemeral matters: the pod
   keeps no state, so each restart registers a new peer and NetBird removes the old offline one after ~10 min.
   Store the key in Proton Pass as the password of login item `netbird-router` in vault `Homelab Secrets Vault`; the `ProtonSecret` in
   `netbird-router/manifests/` turns it into the Secret the pod reads.
3. **Networks -> Add network** `homelab-lb`: resources `192.168.0.200/29` and `192.168.0.208/28` (covers the pool
   `.200-.220`), routing peer **group** `k8s-router` (a group, not a single peer, so a replaced pod takes over by itself).
4. **Access control**: policy `admins` -> `homelab-lb` resources (TCP 443/80 for the gateway, 445 for Samba, or all),
   and `admins` -> the host agent for SSH.
5. NetBird clients must resolve `*.chiragsoni.org` to `192.168.0.200`: Cloudflare records (see [TLS](tls.md)) or a
   NetBird DNS zone.

Check: `kubectl -n netbird logs deploy/netbird-router`, `kubectl -n netbird exec deploy/netbird-router -- netbird status -d`
(`Networks:` lists the routes it serves); from a laptop on NetBird: `curl -sI https://jellyfin.chiragsoni.org/`.
