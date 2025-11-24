#!/bin/bash
set -e

# Usage: ./build.sh [rpi5|rock5b] [gold|flasher]

TARGET_BOARD=$1
IMAGE_TYPE=$2

if [[ -z "$TARGET_BOARD" || -z "$IMAGE_TYPE" ]]; then
    echo "Usage: ./build.sh [rpi5|rock5b] [gold|flasher]"
    exit 1
fi

# Validate arguments
if [[ "$TARGET_BOARD" != "rpi5" && "$TARGET_BOARD" != "rock5b" ]]; then
    echo "Error: Target board must be 'rpi5' or 'rock5b'"
    exit 1
fi

if [[ "$IMAGE_TYPE" != "gold" && "$IMAGE_TYPE" != "flasher" ]]; then
    echo "Error: Image type must be 'gold' or 'flasher'"
    exit 1
fi

echo "🚀 Starting Ironstone Build Pipeline"
echo "Target: $TARGET_BOARD"
echo "Type:   $IMAGE_TYPE"

# Define paths
REPO_ROOT=$(pwd)
PROVISIONING_DIR="/workspace/provisioning"

# Docker Run Command
# We mount the entire repo to /workspace to ensure ansible roles and packer files are accessible.
# --privileged is required for loopback mounting used by the arm image builder.
docker run --rm -it \
    --privileged \
    -v "${REPO_ROOT}:/workspace" \
    -w "${PROVISIONING_DIR}/packer" \
    -e TARGET_BOARD="$TARGET_BOARD" \
    -e IMAGE_TYPE="$IMAGE_TYPE" \
    -e K3S_TOKEN="${K3S_TOKEN}" \
    mkaczanowski/packer-builder-arm \
    /bin/sh -c "apt-get update && apt-get install -y ansible nfs-common && packer init ironstone.pkr.hcl && packer build -var 'target_board=${TARGET_BOARD}' -var 'image_type=${IMAGE_TYPE}' -var 'k3s_token=${K3S_TOKEN}' ironstone.pkr.hcl"
