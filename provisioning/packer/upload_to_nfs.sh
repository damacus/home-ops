#!/bin/bash
set -e

# Arguments: $1 = image_path, $2 = target_board, $3 = image_type
IMAGE_PATH=$1
TARGET_BOARD=$2
IMAGE_TYPE=$3
NFS_SERVER="192.168.1.243"
NFS_SHARE="/volume1/NFS"

if [ "$IMAGE_TYPE" != "gold" ]; then
    echo "Image type is '$IMAGE_TYPE', skipping upload."
    exit 0
fi

echo "Uploading Gold Master to NFS..."

mkdir -p /mnt/nfs_upload
mount -t nfs -o nolock ${NFS_SERVER}:${NFS_SHARE} /mnt/nfs_upload

DEST_NAME="${TARGET_BOARD}-gold-latest.img"
echo "Copying $IMAGE_PATH to /mnt/nfs_upload/$DEST_NAME ..."
cp "$IMAGE_PATH" "/mnt/nfs_upload/$DEST_NAME"

echo "Upload complete."
umount /mnt/nfs_upload
