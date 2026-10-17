# Networking

```
Internet - ISP router 192.168.1.0/24 - TP-Link (WAN) - TP-Link LAN 192.168.0.0/24
                                                         |- Dell  (master) 192.168.0.160
                                                         |- Asus  (worker) 192.168.0.161
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
`gitops/apps/platform/cilium/lb-ippool.yaml` gives Cilium the range. A Service of `type: LoadBalancer` gets an IP from it;
one node answers ARP for that IP (leader election), so any LAN device can reach it. Envoy Gateway's Service is pinned to
`192.168.0.200` (annotation `lbipam.cilium.io/ips` in `gateway.yaml`). Point DNS names (`*.home...`) at that IP and route
with `HTTPRoute`s.

## NetBird (host-level)
`scripts/70-netbird.sh` installs the agent on the node OS (works even if Kubernetes is down). In the NetBird console:
make a node a **routing peer** for `192.168.0.0/24` (or just the LB range + node IPs), then restrict with ACL groups.
