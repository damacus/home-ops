#!/bin/bash
set -euo pipefail

# K3s Token Retrieval Script
# Fetches cluster token from NFS share using config from /etc/ironstone/config

LOG_TAG="k3s-init"
log() { logger -t "$LOG_TAG" "$*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Source build-time configuration
if [ -f /etc/ironstone/config ]; then
    source /etc/ironstone/config
else
    log "ERROR: /etc/ironstone/config not found"
    exit 1
fi

TOKEN_PATH="provisioning/token"
TOKEN_FILE="/etc/rancher/k3s/cluster-token"
MOUNT_POINT="/mnt/nfs-token"

mkdir -p "$MOUNT_POINT"
mkdir -p "$(dirname "$TOKEN_FILE")"

if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
    log "K3s cluster token already exists, skipping NFS fetch"
    exit 0
fi

log "Fetching k3s cluster token from NFS..."

if timeout 10s mount -t nfs "${NFS_SERVER}:${NFS_SHARE}" "$MOUNT_POINT" -o ro,nolock,nfsvers=3,soft,timeo=10,retrans=1 2>/dev/null; then
    if [ -f "$MOUNT_POINT/$TOKEN_PATH" ]; then
        cp "$MOUNT_POINT/$TOKEN_PATH" "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        log "K3s cluster token copied successfully"
    else
        log "ERROR: Token not found at $MOUNT_POINT/$TOKEN_PATH"
        umount "$MOUNT_POINT" 2>/dev/null || true
        exit 1
    fi
    umount "$MOUNT_POINT" 2>/dev/null || true
else
    log "ERROR: Failed to mount NFS"
    exit 1
fi

rmdir "$MOUNT_POINT" 2>/dev/null || true
