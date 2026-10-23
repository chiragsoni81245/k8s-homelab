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

## NetBird (host-level)
`scripts/70-netbird.sh` installs the agent on the node OS (works even if Kubernetes is down). In the NetBird console:
make a node a **routing peer** for `192.168.0.0/24` (or just the LB range + node IPs), then restrict with ACL groups.

Reaching LoadBalancer IPs (e.g. `192.168.0.200`) over NetBird:
- Cilium is kept off `wt0` (`devices: "en+,eth+"` in the Cilium values). Auto-detected, Cilium's eBPF on `wt0` took LB-IP
  traffic before NetBird's forward ACL (`sudo nft list table ip netbird`, chain `netbird-rt-fwd`) and it was silently lost.
  Now the routing peer forwards it normally: NetBird policy -> masquerade -> LAN -> the node announcing the LB IP.
- The routing peer must **not** be the node announcing the LB IP (a node can't ARP-resolve its own announced IP).
  So L2 announcements are pinned to the Asus (`cilium/manifests/ciliuml2announcementpolicy-homelab.yaml`, `homelab/storage=media`) and the Dell is the routing
  peer - don't make the Asus a routing peer for the LB IPs. Check the holder: `kubectl -n kube-system get lease | grep l2announce`.
```
laptop -WireGuard-> Dell wt0 -NetBird policy + masquerade-> enp5s0 -ARP .200-> Asus -Cilium-> Envoy (Asus)
```
