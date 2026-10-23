# Storage

| StorageClass | Type | Where data lives | Use for |
|---|---|---|---|
| `local-data` | static local PVs, **declared by each app** | folders on the node that has the `/DATA` partition (existing, never formatted) | media, downloads, app config you want to survive rebuilds |
| `local-path` | dynamic (Rancher local-path-provisioner) | `/var/lib/local-path` on the node the pod lands on | small disposable volumes |

## Pattern: every app brings its own PV + PVC + pod
There is no shared "data" volume. Each app declares exactly the folder(s) it needs:
```
/DATA/Media                    -> Jellyfin            (apps/workloads/jellyfin/manifests: persistentvolume-* + persistentvolumeclaim-*)
/DATA/AppData/jellyfin-k8s     -> Jellyfin config      (same files)
/DATA/Downloads/Torrent        -> Transmission         (apps/workloads/transmission/manifests, same pattern)
/DATA/AppData/transmission-k8s -> Transmission config  (same files)
```
Exception: **Samba** (`apps/workloads/samba`) shares the whole partition over SMB (`smb://192.168.0.201/<share>`), so it
mounts `/DATA` with a `hostPath` instead of a PV. Its users, groups and per-share access are env vars in
`manifests/configmap-samba-config.yaml` (passwords in the hand-made Secret `samba-users`); nothing is created on the host.
A PV for a new app (copy `apps/workloads/jellyfin/manifests/persistentvolume-jellyfin-media.yaml`):
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: transmission-downloads
spec:
  capacity:
    storage: 500Gi                         # nominal, not enforced
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-data
  local:
    path: /DATA/Downloads/Torrent          # the folder must already exist
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: homelab/storage
              operator: In
              values:
                - media
```
plus a PVC in the app's namespace with `volumeName: transmission-downloads`. The PV's `nodeAffinity` makes the scheduler
put any pod using the claim onto the node that has `/DATA` automatically. `tests/unit/gitops.bats` enforces this pattern (class, Retain, pinned, under `/DATA/`, has a claim).

- **Folders must exist first.** A `local` PV does not create its folder. If it's missing, the pod stays `ContainerCreating`
  with a "path does not exist" event. Create it once (`sudo mkdir -p ...`, `chown` to the app's user).
- **If `/DATA` is not mounted** the folders don't exist either, so pods fail to start instead of writing to the root disk.
- **Run pods as the owner of the files**, with numeric `runAsUser/runAsGroup` (the setup script asks for `DATA_PUID/DATA_PGID`).
  Avoid `fsGroup` (recursive chown of the library). Folders like `Media/Movies` are `drwxr-x--x chirag:smbgroup`: run as that
  owner or add the group's number to `supplementalGroups`.
- **Separate mounts = no hardlinks.** `Downloads/Torrent` and `Media` are different mounts inside pods, so moving a finished
  download into `Media` is a copy, not an instant move. If you later add Sonarr/Radarr that want hardlinks, give those apps one
  PV for the common parent (`/DATA`) instead.
- Old Docker configs under `/DATA/AppData/<app>` can be reused by pointing a PV at them; Jellyfin deliberately uses a new folder
  (`jellyfin-k8s`) so nothing gets migrated.

Small disposable volumes: PVC with `storageClassName: local-path`. To pin it to a node, set the pod `nodeSelector` key `homelab/disk` to `ssd` (block style, like all YAML in this repo).
