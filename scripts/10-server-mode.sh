#!/usr/bin/env bash
# 10-server-mode.sh - sourced by setup.sh (both roles)
# What : make the machine behave like a headless server.
#        Wi-Fi/Bluetooth off (only if present; see DISABLE_WIRELESS), lid/power button never suspend, console blanks, no surprise reboots.
# Files: templates/system/{homelab-rfkill.service,logind-homelab.conf,grub-consoleblank.cfg,unattended-upgrades-no-reboot.conf}

# Kernel modules (drivers) of every wireless NIC found on this machine.
wireless_driver_modules() {
  local dir module
  for dir in /sys/class/net/*/wireless; do
    [[ -d "$dir" ]] || continue
    module="$(basename "$(readlink -f "$(dirname "$dir")/device/driver/module" 2>/dev/null)" 2>/dev/null || true)"
    [[ -n "$module" && "$module" != "." ]] && echo "$module"
  done
}

disable_wireless() {
  # block now, and again on every boot
  have rfkill && rfkill block wifi bluetooth 2>/dev/null || true
  install_file system/homelab-rfkill.service /etc/systemd/system/homelab-rfkill.service
  systemctl daemon-reload
  systemctl enable homelab-rfkill.service >/dev/null 2>&1 || true

  # never load the drivers
  local wifi_modules bt_modules="btusb bluetooth btintel btrtl btbcm btmtk" module
  wifi_modules="$(wireless_driver_modules | tr '\n' ' ')"
  {
    echo "# managed by k8s-homelab: no Wi-Fi / Bluetooth on a server"
    for module in $wifi_modules $bt_modules; do
      echo "blacklist $module"
      echo "install $module /bin/false"
    done
  } | write_file /etc/modprobe.d/homelab-no-wireless.conf || true
  log "Wireless blocked (Wi-Fi drivers: ${wifi_modules:-none found})"

  # stop the userspace services too
  local svc
  for svc in bluetooth wpa_supplicant ModemManager cups-browsed; do
    systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc" || continue
    systemctl disable --now "$svc.service" >/dev/null 2>&1 || true
    systemctl mask "$svc.service" >/dev/null 2>&1 || true
  done
  if grep -rqs '^[[:space:]]*wifis:' /etc/netplan/; then
    warn "netplan has a 'wifis:' section - remove it (not auto-edited to avoid breaking networking)."
  fi
}

ignore_lid_and_sleep() {
  install_file system/logind-homelab.conf /etc/systemd/logind.conf.d/10-homelab.conf
  [[ "$CHANGED" == 1 ]] && systemctl kill -s HUP systemd-logind || true
  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
  log "Lid close / power button / idle will not suspend this machine"
}

blank_console() {
  [[ -d /etc/default/grub.d ]] || return 0
  install_file system/grub-consoleblank.cfg /etc/default/grub.d/99-homelab.cfg
  [[ "$CHANGED" == 1 ]] && have update-grub && update-grub >/dev/null 2>&1 || true
}

housekeeping() {
  install_file system/unattended-upgrades-no-reboot.conf /etc/apt/apt.conf.d/52homelab-unattended
  [[ "$(disk_kind)" == ssd ]] && systemctl enable --now fstrim.timer >/dev/null 2>&1 || true
}

if wireless_should_be_disabled; then
  disable_wireless
else
  log "Wireless left alone (DISABLE_WIRELESS=$DISABLE_WIRELESS, no Wi-Fi/Bluetooth hardware or disabled by setting)"
fi
ignore_lid_and_sleep
blank_console
housekeeping
log "Server mode configured"
