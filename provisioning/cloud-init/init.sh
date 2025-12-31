#!/bin/bash
# =============================================================================
# Ironstone First-Boot Bootstrap
# =============================================================================
# Runs before cloud-init to set hostname based on MAC address.
# This is the ONLY script needed before cloud-init.
# MUST NOT block boot - always exits 0.
# =============================================================================

LOG_TAG="ironstone-init"
log() { logger -t "$LOG_TAG" "$*" 2>/dev/null || true; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "Starting ironstone-init..."

# Get MAC from any ethernet interface (don't wait for network)
get_mac() {
    # Try default route interface first
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -n "$iface" ] && [ -f "/sys/class/net/$iface/address" ]; then
        cat "/sys/class/net/$iface/address" 2>/dev/null
        return
    fi

    # Fallback: find first ethernet interface (eth*, en*, end*)
    for pattern in eth en end; do
        for iface in /sys/class/net/${pattern}*; do
            [ -d "$iface" ] || continue
            cat "$iface/address" 2>/dev/null && return
        done
    done
}

MAC=$(get_mac)
if [ -z "$MAC" ]; then
    log "WARNING: No MAC address found, using fallback hostname"
    HOSTNAME="node-unknown"
else
    # Derive hostname: node-<last 6 hex of MAC>
    HOSTNAME="node-$(echo "$MAC" | tr -d ':' | tail -c 7)"
    log "MAC: $MAC -> Hostname: $HOSTNAME"
fi

# Set hostname for cloud-init to pick up
echo "$HOSTNAME" > /etc/hostname
hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || hostname "$HOSTNAME" 2>/dev/null || true

log "Hostname set to $HOSTNAME"
log "ironstone-init complete"

# Always exit 0 to not block boot
exit 0
