#!/bin/bash
# =============================================================================
# Ironstone First-Boot Bootstrap
# =============================================================================
# Runs before cloud-init to set hostname based on MAC address.
# This is the ONLY script needed before cloud-init.
# =============================================================================
set -euo pipefail

LOG_TAG="ironstone-init"
log() { logger -t "$LOG_TAG" "$*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Get MAC from default route interface
get_mac() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    [ -n "$iface" ] && cat "/sys/class/net/$iface/address" 2>/dev/null
}

# Wait for network
sleep 2

MAC=$(get_mac)
if [ -z "$MAC" ]; then
    # Fallback: find first ethernet interface
    for iface in /sys/class/net/e*; do
        [ -d "$iface" ] || continue
        MAC=$(cat "$iface/address" 2>/dev/null) && break
    done
fi

if [ -z "$MAC" ]; then
    log "ERROR: No MAC address found"
    exit 1
fi

# Derive hostname: node-<last 6 hex of MAC>
HOSTNAME="node-$(echo "$MAC" | tr -d ':' | tail -c 7)"
log "MAC: $MAC -> Hostname: $HOSTNAME"

# Set hostname for cloud-init to pick up
echo "$HOSTNAME" > /etc/hostname
hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || hostname "$HOSTNAME"

log "Hostname set to $HOSTNAME"
