# TLS with Let's Encrypt (cert-manager + Cloudflare DNS-01)

One wildcard certificate, `*.chiragsoni.org`, terminates HTTPS on the Envoy Gateway (port 443, `192.168.0.200`).
Wildcards need the **DNS-01** challenge: cert-manager proves ownership by creating a TXT record through the Cloudflare API.
Your apps never need to be reachable from the internet.

> `*.chiragsoni.org` covers **one** level: `jellyfin.chiragsoni.org` works, `jellyfin.homelab.chiragsoni.org` does not.
> (The API endpoint `k8s-api.homelab.chiragsoni.org` is unaffected - the API server uses its own certificates.)

## One-time steps (you)
1. Cloudflare -> My Profile -> API Tokens -> Create Token -> "Edit zone DNS" template, restricted to the zone `chiragsoni.org`
   (permissions: Zone/DNS/Edit and Zone/Zone/Read).
2. On the master: `sudo tools/create-cloudflare-secret.sh` (paste the token; input is hidden, nothing is written to disk or git).
3. Watch it issue: `kubectl -n envoy-gateway-system get certificate` -> `READY True` (first time takes ~1-3 minutes).
   If not: `kubectl -n cert-manager get challenges,orders` and `kubectl -n envoy-gateway-system describe certificate wildcard-chiragsoni-org`.
4. It started on the **staging** issuer (browsers do not trust it); it now points at production. To go back to staging, edit
   `gitops/apps/platform/cert-manager-issuers/certificate-wildcard.yaml`: `issuerRef.name: letsencrypt-prod`, commit, push.
   Argo re-issues a trusted certificate. Renewal is automatic (~30 days before expiry).

## DNS records so your devices find the apps
Gateway IP is `192.168.0.200`. Add records in Cloudflare (**DNS only**, grey cloud - not proxied) for each app, e.g.
`jellyfin.chiragsoni.org  A  192.168.0.200`, or use a local override (TP-Link DNS / `/etc/hosts` / NetBird DNS) so the private
IP is not published in public DNS. Avoid a wildcard `*.chiragsoni.org A` record: it would also catch every other subdomain.

## Adding an app with TLS
Attach an `HTTPRoute` to the shared Gateway; the `https` listener already matches `*.chiragsoni.org`:
```yaml
parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: homelab
    namespace: envoy-gateway-system
hostnames:
  - myapp.chiragsoni.org
```
**HTTPS only, enforced by the Gateway** (nothing to add per route). The `http` listener (port 80) accepts routes from
`envoy-gateway-system` only, so app routes attach to `https` alone; the single route on port 80 (`https-redirect` in
`gateway.yaml`) answers every plain-HTTP request with a 301 to `https://<same host and path>`.
Check: `curl -sI http://jellyfin.chiragsoni.org/` -> `301` with `location: https://jellyfin.chiragsoni.org/`.
