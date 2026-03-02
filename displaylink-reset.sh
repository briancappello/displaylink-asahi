#!/usr/bin/bash
#
# displaylink-reset.sh — manually recover DisplayLink external displays
# after a failed sleep/wake cycle.
#
# Usage: sudo ./displaylink-reset.sh
#

set -euo pipefail

log() { echo "[displaylink-reset] $*"; }
warn() { echo "[displaylink-reset] WARNING: $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Clean up stale guard files and broken IPC pipes
# ---------------------------------------------------------------------------
log "Cleaning up stale state..."
rm -f /run/displaylink-suspending

# The upstream daemon uses named pipes for IPC. After a bad sleep/wake cycle
# these can end up as regular files (broken by shell redirects) or stale.
# Remove them so DisplayLinkManager recreates them fresh on start.
for f in /tmp/PmMessagesPort_in /tmp/PmMessagesPort_out; do
  if [[ -e "$f" ]]; then
    if [[ -p "$f" ]]; then
      log "  Removing stale FIFO: $f"
    else
      log "  Removing broken non-FIFO: $f (was $(file -b "$f"))"
    fi
    rm -f "$f"
  fi
done

# ---------------------------------------------------------------------------
# 2. Stop the service (SIGKILL — DisplayLinkManager ignores SIGTERM)
# ---------------------------------------------------------------------------
log "Stopping displaylink-driver.service..."
if systemctl is-active --quiet displaylink-driver.service; then
  systemctl kill --signal=SIGKILL displaylink-driver.service 2>/dev/null || true
  # Give systemd a moment to notice the process died
  sleep 1
  systemctl stop displaylink-driver.service 2>/dev/null || true
else
  log "  Service was not running."
fi

# Also kill any orphaned DisplayLinkManager processes
if pgrep -x DisplayLinkMana >/dev/null 2>&1; then
  log "  Killing orphaned DisplayLinkManager processes..."
  pkill -9 -x DisplayLinkMana 2>/dev/null || true
  sleep 1
fi

# ---------------------------------------------------------------------------
# 3. Reset the USB port if the dock has disappeared from the bus
# ---------------------------------------------------------------------------
dock_present() {
  grep -rqsw 17e9 /sys/bus/usb/devices/*/idVendor 2>/dev/null
}

if ! dock_present; then
  log "DisplayLink dock not found on USB bus. Attempting USB reset..."

  # Find the xHCI controller(s) and rebind them to re-enumerate all devices.
  for xhci in /sys/bus/pci/drivers/xhci_hcd/????:??:??.?; do
    if [[ -d "$xhci" ]]; then
      dev=$(basename "$xhci")
      log "  Rebinding PCI xHCI controller: $dev"
      echo "$dev" > /sys/bus/pci/drivers/xhci_hcd/unbind 2>/dev/null || true
      sleep 1
      echo "$dev" > /sys/bus/pci/drivers/xhci_hcd/bind 2>/dev/null || true
    fi
  done

  # On Apple Silicon the xHCI controller is a platform device, not PCI.
  # Try rebinding the platform xhci-hcd driver instead.
  if ! dock_present; then
    for xhci in /sys/bus/platform/drivers/xhci-hcd/*/; do
      if [[ -d "$xhci" ]]; then
        dev=$(basename "$xhci")
        # Skip entries that aren't actual devices (e.g. "module", "uevent")
        [[ -f "$xhci/uevent" ]] || continue
        log "  Rebinding platform xHCI controller: $dev"
        echo "$dev" > /sys/bus/platform/drivers/xhci-hcd/unbind 2>/dev/null || true
        sleep 2
        echo "$dev" > /sys/bus/platform/drivers/xhci-hcd/bind 2>/dev/null || true
      fi
    done
  fi

  # Wait for USB re-enumeration
  log "  Waiting for USB re-enumeration..."
  for i in $(seq 1 15); do
    if dock_present; then
      log "  DisplayLink dock detected on USB bus after ${i}s."
      break
    fi
    sleep 1
  done

  if ! dock_present; then
    warn "DisplayLink dock still not found on USB bus after 15 seconds."
    warn "The dock may need to be physically unplugged and replugged."
    warn "Continuing anyway in case the service can recover..."
  fi
else
  log "DisplayLink dock found on USB bus."
fi

# ---------------------------------------------------------------------------
# 4. Reload the evdi kernel module
# ---------------------------------------------------------------------------
log "Reloading evdi kernel module..."
if lsmod | grep -qw evdi; then
  modprobe -r evdi 2>/dev/null || {
    warn "Could not unload evdi (may be in use). Continuing with existing module."
  }
fi
modprobe evdi
sleep 1

# ---------------------------------------------------------------------------
# 5. Start the service
# ---------------------------------------------------------------------------
log "Starting displaylink-driver.service..."
systemctl start displaylink-driver.service

# Wait for the daemon to initialise
sleep 3

# ---------------------------------------------------------------------------
# 6. Trigger udev to re-discover the dock
# ---------------------------------------------------------------------------
if dock_present; then
  log "Triggering udev re-enumeration for DisplayLink devices..."
  grep -lw 17e9 /sys/bus/usb/devices/*/idVendor 2>/dev/null | while IFS= read -r f; do
    devpath=$(dirname "$f")
    log "  Triggering: $(basename "$devpath")"
    udevadm trigger --action=add "$devpath"
  done
  sleep 2
fi

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
log ""
log "=== Status ==="

if systemctl is-active --quiet displaylink-driver.service; then
  log "Service: RUNNING (PID $(systemctl show -p MainPID displaylink-driver.service --value))"
else
  warn "Service: NOT RUNNING"
fi

usb_count=$(grep -rlw 17e9 /sys/bus/usb/devices/*/idVendor 2>/dev/null | wc -l)
log "USB devices (vendor 17e9): $usb_count"

# Check evdi connector states
connected=0
for c in /sys/class/drm/card*-DVI-I-*/status; do
  if [[ -f "$c" ]] && [[ "$(cat "$c")" == "connected" ]]; then
    name=$(basename "$(dirname "$c")")
    log "  $name: connected"
    connected=$((connected + 1))
  fi
done

if [[ $connected -gt 0 ]]; then
  log "External displays connected: $connected"
  log ""
  log "If displays are still blank, try: kscreen-doctor --outputs"
  log "or switch to a TTY and back (Ctrl+Alt+F2, then Ctrl+Alt+F1)."
else
  warn "No external displays connected via evdi."
  warn ""
  warn "If the dock is physically connected, try:"
  warn "  1. Unplug and replug the USB-C cable to the dock"
  warn "  2. Then run this script again"
fi
