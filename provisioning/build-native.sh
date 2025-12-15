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
TIMESTAMP=$(date +%Y%m%d)
# GIT_SHA can be passed as env var from host (Lima VM can't access .git)
GIT_SHA="${GIT_SHA:-unknown}"
ARTIFACT_NAME="${TARGET_BOARD}-gold-${GIT_SHA}-${TIMESTAMP}.img"

# Load config
source "${SCRIPT_DIR}/config.env" 2>/dev/null || true

# Image URLs and checksums - Official Raspberry Pi OS Lite ARM64 (December 2025)
RPI5_IMAGE_URL="${RPI5_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-12-04/2025-12-04-raspios-trixie-arm64-lite.img.xz}"
RPI5_IMAGE_SHA256="681a775e20b53a9e4c7341d748a5a8cdc822039d8c67c1fd6ca35927abbe6290"

# Rock 5B - Armbian Trixie Vendor Minimal (pinned version for reproducibility)
ROCK5B_IMAGE_URL="https://dl.armbian.com/rock-5b/archive/Armbian_25.11.1_Rock-5b_trixie_vendor_6.1.115_minimal.img.xz"
ROCK5B_IMAGE_SHA256="a5723585adf42ab32567b43d2e2fe5107c749ad2272e5ae4560b48e418905fe2"

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
    EXPECTED_SHA256="$RPI5_IMAGE_SHA256"
elif [[ "$TARGET_BOARD" == "rock5b" ]]; then
    BASE_IMAGE_URL="$ROCK5B_IMAGE_URL"
    EXPECTED_SHA256="$ROCK5B_IMAGE_SHA256"
else
    echo "Error: Unknown target board $TARGET_BOARD"
    exit 1
fi

echo "Expected SHA256: $EXPECTED_SHA256"

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

    # Verify checksum before extraction
    echo "Verifying image checksum..."
    ACTUAL_SHA256=$(sha256sum "$CACHED_IMAGE" | awk '{print $1}')
    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
        echo "ERROR: Checksum verification failed!"
        echo "  Expected: $EXPECTED_SHA256"
        echo "  Actual:   $ACTUAL_SHA256"
        echo "Removing corrupted download..."
        rm -f "$CACHED_IMAGE"
        exit 1
    fi
    echo "Checksum verified successfully."

    echo "Extracting image..."
    xz -dk "$CACHED_IMAGE"
else
    # Verify cached image checksum
    echo "Verifying cached image checksum..."
    ACTUAL_SHA256=$(sha256sum "$CACHED_IMAGE" | awk '{print $1}')
    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
        echo "WARNING: Cached image checksum mismatch, re-downloading..."
        rm -f "$CACHED_IMAGE" "${CACHED_IMAGE%.xz}"
        echo "Downloading base image..."
        curl -fsSL "$BASE_IMAGE_URL" -o "$CACHED_IMAGE"

        ACTUAL_SHA256=$(sha256sum "$CACHED_IMAGE" | awk '{print $1}')
        if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
            echo "ERROR: Checksum verification failed after re-download!"
            echo "  Expected: $EXPECTED_SHA256"
            echo "  Actual:   $ACTUAL_SHA256"
            rm -f "$CACHED_IMAGE"
            exit 1
        fi
        echo "Checksum verified successfully."

        echo "Extracting image..."
        xz -dk "$CACHED_IMAGE"
    else
        echo "Cached image checksum verified."
    fi
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
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    # Install packages - initramfs-tools may fail in chroot but packages will still install
    apt-get install -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' \
        python3 python3-pip ansible curl
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
        -e 'cloud_init_url=${CLOUD_INIT_URL:-https://provision.ironstone.casa/}' \
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
