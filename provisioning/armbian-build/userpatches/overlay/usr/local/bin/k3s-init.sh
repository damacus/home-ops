#!/bin/bash
set -e

# NFS Server and Share for cluster token
# These should be replaced or templated, but for now we assume they are injected
# or we use a discovery mechanism.
# Based on REQ-K3S-005, this script handles token retrieval.

NFS_SERVER="${NFS_SERVER:-192.168.1.10}"
NFS_SHARE="${NFS_SHARE:-/volume1/k3s-token}"
MOUNT_POINT="/mnt/k3s-token"
TOKEN_FILE="/etc/rancher/k3s/cluster-token"

mkdir -p "${MOUNT_POINT}"

# Mount NFS (REQ-NFS-002: safe options)
mount -t nfs -o ro,noexec,nosuid,nfsvers=4 "${NFS_SERVER}:${NFS_SHARE}" "${MOUNT_POINT}"

if [ -f "${MOUNT_POINT}/token" ]; then
    mkdir -p "$(dirname "${TOKEN_FILE}")"
    cp "${MOUNT_POINT}/token" "${TOKEN_FILE}"
    chmod 0600 "${TOKEN_FILE}"
    chown root:root "${TOKEN_FILE}"
    echo "Cluster token retrieved successfully."
else
    echo "Error: Token file not found on NFS share."
    umount "${MOUNT_POINT}"
    exit 1
fi

umount "${MOUNT_POINT}"
