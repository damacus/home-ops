#!/bin/bash
set -euo pipefail

# =============================================================================
# Upload Gold Master to NFS
# =============================================================================
# Arguments: $1 = image_path, $2 = target_board, $3 = image_type
# Environment: NFS_SERVER, NFS_SHARE (from Packer post-processor)

IMAGE_PATH="${1:-}"
TARGET_BOARD="${2:-}"
IMAGE_TYPE="${3:-}"

# Use environment variables with defaults
NFS_SERVER="${NFS_SERVER:-192.168.1.243}"
NFS_SHARE="${NFS_SHARE:-/volume1/NFS}"

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
if [[ -z "$IMAGE_PATH" || -z "$TARGET_BOARD" || -z "$IMAGE_TYPE" ]]; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 <image_path> <target_board> <image_type>"
    exit 1
fi

if [[ ! -f "$IMAGE_PATH" ]]; then
    echo "Error: Image file not found: $IMAGE_PATH"
    exit 1
fi

if [[ "$IMAGE_TYPE" != "gold" ]]; then
    echo "Image type is '$IMAGE_TYPE', skipping upload."
    exit 0
fi

if [[ "${SKIP_UPLOAD:-false}" == "true" ]]; then
    echo "Skipping upload (SKIP_UPLOAD=true)"
    exit 0
fi

# -----------------------------------------------------------------------------
# Upload
# -----------------------------------------------------------------------------
echo "========================================"
echo "Uploading Gold Master to NFS"
echo "========================================"
echo "Source:      $IMAGE_PATH"
echo "NFS Server:  $NFS_SERVER"
echo "NFS Share:   $NFS_SHARE"
echo "========================================"

MOUNT_POINT="/mnt/nfs_upload"
mkdir -p "$MOUNT_POINT"

# Cleanup on exit
cleanup() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" || true
    fi
}
trap cleanup EXIT

# Mount NFS share
echo "Mounting NFS share..."
if ! mount -t nfs -o nolock "${NFS_SERVER}:${NFS_SHARE}" "$MOUNT_POINT"; then
    echo "Error: Failed to mount NFS share"
    exit 1
fi

# Copy with both versioned and latest names
SOURCE_BASENAME=$(basename "$IMAGE_PATH")
LATEST_NAME="${TARGET_BOARD}-gold-latest.img"

echo "Copying $SOURCE_BASENAME to NFS..."
cp "$IMAGE_PATH" "${MOUNT_POINT}/${SOURCE_BASENAME}"

# Create/update the 'latest' symlink or copy
echo "Updating latest pointer: $LATEST_NAME"
ln -sf "$SOURCE_BASENAME" "${MOUNT_POINT}/${LATEST_NAME}" 2>/dev/null || \
    cp "$IMAGE_PATH" "${MOUNT_POINT}/${LATEST_NAME}"

echo "========================================"
echo "Upload Complete!"
echo "  Versioned: ${SOURCE_BASENAME}"
echo "  Latest:    ${LATEST_NAME}"
echo "========================================"
