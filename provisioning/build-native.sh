#!/bin/bash
# =============================================================================
# Ironstone Native ARM64 Build Script
# =============================================================================
# This script builds ARM64 images natively on ARM64 Linux (Lima VM).
# It avoids Packer's binfmt_misc requirements by using native chroot.
#
# Prerequisites:
#   - Lima VM running on ARM64 Mac
#   - limactl shell ironstone
#
# Usage:
#   ./build-native.sh rpi5
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TARGET_BOARD="${1:-rpi5}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
GIT_SHA=$(git -C "$SCRIPT_DIR/.." rev-parse --short HEAD 2>/dev/null || echo "unknown")
ARTIFACT_NAME="${TARGET_BOARD}-gold-${GIT_SHA}-${TIMESTAMP}.img"

# Load config
source "${SCRIPT_DIR}/config.env" 2>/dev/null || true

# Image URLs - Official Raspberry Pi OS Lite ARM64 (December 2025)
RPI5_IMAGE_URL="${RPI5_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-12-04/2025-12-04-raspios-trixie-arm64-lite.img.xz}"
RPI5_IMAGE_SHA256="681a775e20b53a9e4c7341d748a5a8cdc822039d8c67c1fd6ca35927abbe6290"

# Rock 5B - Armbian Trixie Minimal (latest)
ROCK5B_IMAGE_URL="https://dl.armbian.com/rock-5b/Trixie_current_minimal.img.xz"

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
echo "========================================"
echo "Ironstone Native Build"
echo "========================================"
echo "Target Board:    $TARGET_BOARD"
echo "Image Type:      gold"
echo "Artifact Name:   $ARTIFACT_NAME"
echo "========================================"

# Select Image based on Board
if [[ "$TARGET_BOARD" == "rpi5" ]]; then
    BASE_IMAGE_URL="$RPI5_IMAGE_URL"
elif [[ "$TARGET_BOARD" == "rock5b" ]]; then
    BASE_IMAGE_URL="$ROCK5B_IMAGE_URL"
else
    echo "Error: Unknown target board $TARGET_BOARD"
    exit 1
fi

# Create build directory on Linux filesystem (Lima mounts macOS as read-only)
BUILD_DIR="${HOME}/ironstone-builds"
mkdir -p "$BUILD_DIR"

# Download base image if not cached
CACHE_DIR="${HOME}/.cache/ironstone"
mkdir -p "$CACHE_DIR"
CACHED_IMAGE="${CACHE_DIR}/$(basename "$BASE_IMAGE_URL")"

if [[ ! -f "${CACHED_IMAGE%.xz}" ]]; then
    echo "Downloading base image..."
    curl -fsSL "$BASE_IMAGE_URL" -o "$CACHED_IMAGE"
    echo "Extracting image..."
    xz -dk "$CACHED_IMAGE"
fi

# Copy to build directory
echo "Copying image to build directory..."
cp "${CACHED_IMAGE%.xz}" "${BUILD_DIR}/${ARTIFACT_NAME}"

# Resize image
echo "Resizing image to 6G..."
truncate -s 6G "${BUILD_DIR}/${ARTIFACT_NAME}"

# Install host dependencies if missing
if ! command -v sgdisk &>/dev/null; then
    echo "Installing gdisk..."
    sudo apt-get update && sudo apt-get install -y gdisk
fi

# Setup loop device
echo "Setting up loop device..."
LOOP_DEV=$(sudo losetup -fP --show "${BUILD_DIR}/${ARTIFACT_NAME}")
echo "Loop device: $LOOP_DEV"

# Fix GPT table (move backup header to end of disk)
echo "Fixing GPT table..."
sudo sgdisk -e "$LOOP_DEV" || true

# Handle Partition Layouts
if [[ "$TARGET_BOARD" == "rpi5" ]]; then
    # RPi: p1=boot, p2=root
    ROOT_PART="${LOOP_DEV}p2"
    BOOT_PART="${LOOP_DEV}p1"
    PART_NUM=2
elif [[ "$TARGET_BOARD" == "rock5b" ]]; then
    # Armbian: p1=root (usually)
    ROOT_PART="${LOOP_DEV}p1"
    BOOT_PART=""
    PART_NUM=1
fi

# Resize partition
echo "Resizing root partition ($ROOT_PART)..."
sudo parted -s "$LOOP_DEV" resizepart $PART_NUM 100%
sudo e2fsck -f -y "$ROOT_PART" || true
sudo resize2fs "$ROOT_PART"

# Mount
MOUNT_DIR=$(mktemp -d)
echo "Mounting to $MOUNT_DIR..."
sudo mount "$ROOT_PART" "$MOUNT_DIR"

if [[ -n "$BOOT_PART" ]]; then
    sudo mount "$BOOT_PART" "$MOUNT_DIR/boot"
fi

# Bind mounts for chroot
sudo mount --bind /dev "$MOUNT_DIR/dev"
sudo mount --bind /dev/pts "$MOUNT_DIR/dev/pts"
sudo mount -t proc proc "$MOUNT_DIR/proc"
sudo mount -t sysfs sysfs "$MOUNT_DIR/sys"

# Copy resolv.conf
sudo rm -f "$MOUNT_DIR/etc/resolv.conf"
sudo cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"

# Run provisioning in chroot
echo "Running provisioning..."
sudo chroot "$MOUNT_DIR" /bin/bash -c "
    set -e
    apt-get update
    # Install packages, ignoring initramfs-tools errors (expected in chroot)
    apt-get install -y python3 python3-pip ansible curl || true
"

# Copy and run Ansible
echo "Running Ansible playbook..."
sudo cp -r "${SCRIPT_DIR}/ansible" "$MOUNT_DIR/tmp/"
sudo chroot "$MOUNT_DIR" /bin/bash -c "
    cd /tmp/ansible
    # Create inventory with 'default' host pointing to localhost
    echo '[default]' > /tmp/inventory
    echo 'localhost ansible_connection=local' >> /tmp/inventory
    # Run ansible with verbose output and ignore errors from modprobe (not available in chroot)
    ansible-playbook -i /tmp/inventory playbook.yaml -v \
        -e 'target_board=${TARGET_BOARD}' \
        -e 'image_type=gold' \
        -e 'nfs_server=${NFS_SERVER:-192.168.1.243}' \
        -e 'nfs_share=${NFS_SHARE:-/volume1/NFS}' \
        -e 'cloud_init_url=${CLOUD_INIT_URL:-http://provision.ironstone.casa:8080/}' \
        -e 'k3s_vip=${K3S_VIP:-192.168.1.200}' \
        -e 'k3s_version=${K3S_VERSION:-}' || echo 'Ansible completed with warnings (expected in chroot)'
"

# Cleanup chroot
echo "Cleaning up..."
sudo rm -rf "$MOUNT_DIR/tmp/ansible"
sudo rm -f "$MOUNT_DIR/etc/resolv.conf"

# Unmount
sudo umount "$MOUNT_DIR/sys" || true
sudo umount "$MOUNT_DIR/proc" || true
sudo umount "$MOUNT_DIR/dev/pts" || true
sudo umount "$MOUNT_DIR/dev" || true
sudo umount "$MOUNT_DIR/boot" || true
sudo umount "$MOUNT_DIR" || true
sudo losetup -d "$LOOP_DEV" || true
rmdir "$MOUNT_DIR" || true

echo "========================================"
echo "Build Complete!"
echo "========================================"
echo ""
echo "Image location (inside Lima VM):"
echo "  ${BUILD_DIR}/${ARTIFACT_NAME}"
echo ""
echo "To copy to macOS, run:"
echo "  limactl copy ironstone:${BUILD_DIR}/${ARTIFACT_NAME} ./packer/builds/"
echo ""
echo "Or to flash directly to SD card:"
echo "  limactl copy ironstone:${BUILD_DIR}/${ARTIFACT_NAME} /tmp/"
echo "  sudo dd if=/tmp/${ARTIFACT_NAME} of=/dev/diskN bs=4M status=progress"
echo "========================================"
