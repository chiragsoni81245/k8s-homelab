# Storage

| StorageClass | Type | Where data lives | Use for |
|---|---|---|---|
| `local-data` | static PV `data-pv` (declared once in git) | Asus `/DATA` (existing partition, never formatted) | media / downloads |
| `local-path` | dynamic (Rancher local-path-provisioner) | `/var/lib/local-path` on the node the pod lands on | small app config/DB volumes |

## /DATA on the Asus
`scripts/35-data-mount.sh` mounts the existing partition by UUID (`nofail`, read-write). The PV has `nodeAffinity`
`homelab/storage=media`, so any pod claiming it is scheduled onto the Asus automatically.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data, namespace: media}
spec:
  accessModes: [ReadWriteOnce]       # one node; several pods on that node may share it
  storageClassName: local-data
  volumeName: data-pv
  resources: {requests: {storage: 800Gi}}
```
- Mount the **one** PVC at a single path (`/data` with `downloads/` and `media/`) in both Jellyfin and Transmission so hardlinks/instant moves work.
- Run pods with `runAsUser/runAsGroup` = the owner of your files (`DATA_PUID/DATA_PGID` in `config.env`; the setup script asks, it does not guess from the top-level owner, which is often root). Avoid `fsGroup` (recursive chown of the library).
- Folders with mode `drwxr-x--x` (e.g. `Media/Movies`, group `smbgroup`) are unreadable to "others": run as that owner, or add `supplementalGroups: [<smbgroup gid>]`.
- Old per-app configs under `/DATA/AppData/<app>` (many are root-owned from Docker) can be mounted with `subPath: AppData/<app>` to reuse them, at the cost of HDD speed for databases.
- The PV is `Retain` and `prune: false`; the cluster can be rebuilt without touching your files.
- Keep Jellyfin's config/cache on the SSD: PVC with `local-path` + `nodeSelector: {homelab/disk: ssd}`.

## Example: Jellyfin + Transmission on the same volume
Both pods mount the same PVC `data` at `/data` (same filesystem => hardlinks / instant moves from `Downloads/Torrent` to `Media`).
```yaml
# Jellyfin: library path /data/Media  (use readOnly: true on the mount only if you don't let Jellyfin write artwork/.nfo)
volumeMounts: [{name: data, mountPath: /data}]
securityContext: {runAsUser: <PUID>, runAsGroup: <PGID>, supplementalGroups: [<smbgroup gid>]}
# Transmission: download dir /data/Downloads/Torrent  (paths are case-sensitive)
volumeMounts: [{name: data, mountPath: /data}]
# both:
volumes: [{name: data, persistentVolumeClaim: {claimName: data}}]
```
Numeric IDs are what matter on disk - a reinstalled OS does not need a user named `chirag`, only pods running with the right numbers.
