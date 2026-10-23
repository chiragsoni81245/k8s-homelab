#!/usr/bin/env bash
# 35-data-mount.sh - sourced by setup.sh (either role; asks, default No)
# What : mount an EXISTING data partition at $DATA_MOUNT (default /DATA), read-write.
#        It NEVER formats anything: a device without a filesystem is refused.
# Sets : DATA_MOUNTED (yes|no), DATA_PUID, DATA_PGID (saved to config.env). A mounted $DATA_MOUNT is what
#        puts the homelab/storage=media label on the node (see node_labels in lib/common.sh).

DATA_MOUNTED=no

resolve_device() {  # UUID or /dev/xxx -> block device path
  local input="$1" dev
  if [[ "$input" == /dev/* ]]; then dev="$input"; else dev="$(blkid -U "$input" || true)"; fi
  [[ -b "$dev" ]] || die "No block device for '$input'."
  echo "$dev"
}

add_fstab_entry() {  # DEVICE
  local dev="$1" fstype uuid
  fstype="$(blkid -s TYPE -o value "$dev" || true)"
  [[ -n "$fstype" ]] || die "$dev has no filesystem. Refusing: this script never creates filesystems."
  uuid="$(blkid -s UUID -o value "$dev")"
  case "$fstype" in
    ntfs*|exfat|vfat) warn "$fstype has no Unix permissions; ext4/xfs is recommended for a media server." ;;
  esac
  mkdir -p "$DATA_MOUNT"
  sed -i "\|[[:space:]]${DATA_MOUNT}[[:space:]]|d" /etc/fstab        # replace an old entry, if any
  echo "UUID=$uuid $DATA_MOUNT $fstype defaults,nofail 0 2 # k8s-homelab" >>/etc/fstab
  systemctl daemon-reload
}

mount_data_partition() {
  echo >&2; lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT >&2; echo >&2
  prompt DATA_DEVICE "Partition to mount at $DATA_MOUNT (UUID, or device like /dev/sda4)"
  add_fstab_entry "$(resolve_device "$DATA_DEVICE")"
  mount "$DATA_MOUNT"
  mountpoint -q "$DATA_MOUNT" || die "Mount failed; check /etc/fstab."
}

# The folder owner is often root, so we ask instead of guessing: default = the user who ran sudo.
ask_app_user_ids() {
  local def_uid def_gid
  def_uid="$(id -u "${SUDO_USER:-root}")"; def_gid="$(id -g "${SUDO_USER:-root}")"
  warn "Owners under $DATA_MOUNT: $(stat -c '%u:%g' "$DATA_MOUNT"/* 2>/dev/null | sort | uniq -c | sort -rn | head -3 | awk '{printf "%s(x%s) ", $2, $1}')"
  prompt DATA_PUID "UID your apps should run as (owner of your files)" "$def_uid"
  prompt DATA_PGID "GID for those apps (a group that can access them)" "$def_gid"
  config_set DATA_PUID "$DATA_PUID"
  config_set DATA_PGID "$DATA_PGID"
  log "Run apps with runAsUser=$DATA_PUID runAsGroup=$DATA_PGID (+ supplementalGroups for other groups)."
}

if mountpoint -q "$DATA_MOUNT"; then
  log "$DATA_MOUNT is already mounted."
  DATA_MOUNTED=yes
elif confirm "Mount an existing data partition at $DATA_MOUNT (read-write, never formatted)?" n; then
  mount_data_partition
  DATA_MOUNTED=yes
fi

if [[ "$DATA_MOUNTED" == yes ]]; then
  [[ -w "$DATA_MOUNT" ]] || warn "$DATA_MOUNT is not writable by root (unexpected)."
  ask_app_user_ids
fi
export DATA_MOUNTED
