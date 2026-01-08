#!/bin/bash
# =============================================================================
# Ironstone Gold Image Build Script
# =============================================================================
# Builds ARM64 gold images natively on ARM64 Linux (Lima VM).
# Uses cloud-init for first-boot configuration.
#
# Prerequisites:
#   - Lima VM running on ARM64 Mac
#   - limactl shell ironstone
#
# Usage:
#   ./build.sh <rock5b|rpi5>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT_DIR="${SCRIPT_DIR}/cloud-init"

# Load config (allows overriding defaults)
source "${SCRIPT_DIR}/config.env" 2>/dev/null || true

require_var() {
    local name
    name="$1"
    if [ -z "${!name:-}" ]; then
        echo "ERROR: ${name} must be set (provisioning/config.env)" >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TARGET_BOARD="${1:-rock5b}"
TIMESTAMP=$(date +%Y%m%d)
GIT_SHA="${GIT_SHA:-unknown}"
ARTIFACT_NAME="${TARGET_BOARD}-gold-${GIT_SHA}-${TIMESTAMP}.img"

# Image URLs and checksums (must be set in config.env)
RPI5_IMAGE_URL="${RPI5_IMAGE_URL:-}"
RPI5_IMAGE_SHA256="${RPI5_IMAGE_SHA256:-}"

ROCK5B_IMAGE_URL="${ROCK5B_IMAGE_URL:-}"
ROCK5B_IMAGE_SHA256="${ROCK5B_IMAGE_SHA256:-}"

# Select image based on board
case "$TARGET_BOARD" in
    rpi5)
        BASE_IMAGE_URL="$RPI5_IMAGE_URL"
        EXPECTED_SHA256="$RPI5_IMAGE_SHA256"
        ;;
    rock5b)
        BASE_IMAGE_URL="$ROCK5B_IMAGE_URL"
        EXPECTED_SHA256="$ROCK5B_IMAGE_SHA256"
        ;;
    *)
        echo "Usage: $0 <rock5b|rpi5>"
        exit 1
        ;;
esac

require_var K3S_VERSION
require_var K3S_VIP
require_var NFS_SERVER
require_var NFS_SHARE
if [ -z "${BASE_IMAGE_URL:-}" ] || [ -z "${EXPECTED_SHA256:-}" ]; then
    echo "ERROR: Image URL/SHA256 missing for board '${TARGET_BOARD}' (provisioning/config.env)" >&2
    exit 1
fi

echo "========================================"
echo "Ironstone Cloud-Init Build"
echo "========================================"
echo "Target Board:    $TARGET_BOARD"
echo "K3s Version:     $K3S_VERSION"
echo "Artifact Name:   $ARTIFACT_NAME"
echo "========================================"

# Build directory
BUILD_DIR="${HOME}/ironstone-builds"
CACHE_DIR="${HOME}/.cache/ironstone"
mkdir -p "$BUILD_DIR" "$CACHE_DIR"

# Install host dependencies if missing
if ! command -v sgdisk &>/dev/null; then
    echo "Installing gdisk..."
    sudo apt-get update && sudo apt-get install -y gdisk
fi

# Download base image if needed
CACHED_IMAGE="${CACHE_DIR}/$(basename "$BASE_IMAGE_URL")"
if [[ ! -f "${CACHED_IMAGE%.xz}" ]]; then
    echo "Downloading base image..."
    curl -fsSL "$BASE_IMAGE_URL" -o "$CACHED_IMAGE"

    echo "Verifying checksum..."
    ACTUAL_SHA256=$(sha256sum "$CACHED_IMAGE" | awk '{print $1}')
    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
        echo "ERROR: Checksum verification failed!"
        echo "  Expected: $EXPECTED_SHA256"
        echo "  Actual:   $ACTUAL_SHA256"
        rm -f "$CACHED_IMAGE"
        exit 1
    fi
    echo "Checksum verified."

    echo "Extracting..."
    xz -dk "$CACHED_IMAGE"
else
    echo "Verifying cached image checksum..."
    ACTUAL_SHA256=$(sha256sum "$CACHED_IMAGE" | awk '{print $1}')
    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
        echo "WARNING: Cached image checksum mismatch, re-downloading..."
        rm -f "$CACHED_IMAGE" "${CACHED_IMAGE%.xz}"
        curl -fsSL "$BASE_IMAGE_URL" -o "$CACHED_IMAGE"

        ACTUAL_SHA256=$(sha256sum "$CACHED_IMAGE" | awk '{print $1}')
        if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
            echo "ERROR: Checksum verification failed after re-download!"
            rm -f "$CACHED_IMAGE"
            exit 1
        fi
        echo "Extracting..."
        xz -dk "$CACHED_IMAGE"
    fi
fi

# Copy to build directory
echo "Creating working copy..."
cp "${CACHED_IMAGE%.xz}" "${BUILD_DIR}/${ARTIFACT_NAME}"

# Resize image
echo "Resizing image to 6G..."
truncate -s 6G "${BUILD_DIR}/${ARTIFACT_NAME}"

# Setup loop device
echo "Setting up loop device..."
LOOP_DEV=$(sudo losetup -fP --show "${BUILD_DIR}/${ARTIFACT_NAME}")
echo "Loop device: $LOOP_DEV"

cleanup() {
    echo "Cleaning up..."
    [ -n "${MOUNT_DIR:-}" ] && sudo umount "$MOUNT_DIR/sys" 2>/dev/null || true
    [ -n "${MOUNT_DIR:-}" ] && sudo umount "$MOUNT_DIR/proc" 2>/dev/null || true
    [ -n "${MOUNT_DIR:-}" ] && sudo umount "$MOUNT_DIR/dev/pts" 2>/dev/null || true
    [ -n "${MOUNT_DIR:-}" ] && sudo umount "$MOUNT_DIR/dev" 2>/dev/null || true
    [ -n "${MOUNT_DIR:-}" ] && sudo umount "$MOUNT_DIR/boot" 2>/dev/null || true
    [ -n "${MOUNT_DIR:-}" ] && sudo umount "$MOUNT_DIR" 2>/dev/null || true
    [ -n "${LOOP_DEV:-}" ] && sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    [ -n "${MOUNT_DIR:-}" ] && rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Fix GPT and resize
sudo sgdisk -e "$LOOP_DEV" 2>/dev/null || true

# Handle partition layouts
if [[ "$TARGET_BOARD" == "rpi5" ]]; then
    ROOT_PART="${LOOP_DEV}p2"
    BOOT_PART="${LOOP_DEV}p1"
    PART_NUM=2
else
    ROOT_PART="${LOOP_DEV}p1"
    BOOT_PART=""
    PART_NUM=1
fi

# Resize partition
echo "Resizing root partition..."
sudo parted -s "$LOOP_DEV" resizepart $PART_NUM 100%
sudo e2fsck -f -y "$ROOT_PART" || true
sudo resize2fs "$ROOT_PART"

# Mount
MOUNT_DIR=$(mktemp -d)
echo "Mounting to $MOUNT_DIR..."
sudo mount "$ROOT_PART" "$MOUNT_DIR"
[[ -n "$BOOT_PART" ]] && sudo mount "$BOOT_PART" "$MOUNT_DIR/boot"

# -----------------------------------------------------------------------------
# Install cloud-init package via chroot
# -----------------------------------------------------------------------------
echo "Installing cloud-init package..."

# Bind mounts for chroot
sudo mount --bind /dev "$MOUNT_DIR/dev"
sudo mount --bind /dev/pts "$MOUNT_DIR/dev/pts"
sudo mount -t proc proc "$MOUNT_DIR/proc"
sudo mount -t sysfs sysfs "$MOUNT_DIR/sys"

# Copy resolv.conf for DNS (handle symlinks in Lima/containers)
sudo rm -f "$MOUNT_DIR/etc/resolv.conf" 2>/dev/null || true
cat /etc/resolv.conf | sudo tee "$MOUNT_DIR/etc/resolv.conf" > /dev/null

# Install cloud-init and nfs-common in chroot
sudo chroot "$MOUNT_DIR" /bin/bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y cloud-init nfs-common
"

# Cleanup chroot mounts
sudo umount "$MOUNT_DIR/sys" || true
sudo umount "$MOUNT_DIR/proc" || true
sudo umount "$MOUNT_DIR/dev/pts" || true
sudo umount "$MOUNT_DIR/dev" || true

# -----------------------------------------------------------------------------
# Install cloud-init configuration
# -----------------------------------------------------------------------------
echo "Installing cloud-init configuration..."

# Create directories
sudo mkdir -p "$MOUNT_DIR/var/lib/cloud/seed/nocloud"
sudo mkdir -p "$MOUNT_DIR/etc/cloud/cloud.cfg.d"
sudo mkdir -p "$MOUNT_DIR/usr/local/bin"
sudo mkdir -p "$MOUNT_DIR/etc/systemd/system"
sudo mkdir -p "$MOUNT_DIR/etc/rancher/k3s"

# Render cloud-init user-data from Jinja template
MAKEJINJA_BIN="$(command -v makejinja || true)"
if [ -z "$MAKEJINJA_BIN" ]; then
    echo "ERROR: makejinja not found. Install python deps (requirements.txt) to use templating." >&2
    exit 1
fi

RENDER_DIR="$(mktemp -d)"
"$MAKEJINJA_BIN" \
    --input "${SCRIPT_DIR}/templates" \
    --output "$RENDER_DIR" \
    --jinja-suffix ".j2" \
    --data-var "K3S_VIP=${K3S_VIP}" \
    --data-var "NFS_SERVER=${NFS_SERVER}" \
    --data-var "NFS_SHARE=${NFS_SHARE}" \
    --force \
    --quiet

sudo cp "$RENDER_DIR/cloud-init/user-data.yaml" "$MOUNT_DIR/var/lib/cloud/seed/nocloud/user-data"
rm -rf "$RENDER_DIR" 2>/dev/null || true
echo "instance-id: ironstone-${TARGET_BOARD}-${GIT_SHA}" | sudo tee "$MOUNT_DIR/var/lib/cloud/seed/nocloud/meta-data" > /dev/null

# Configure datasource for ds-identify detection
# ds-identify checks: seed dir, config with seedfrom, or config with user-data+meta-data
cat <<EOF | sudo tee "$MOUNT_DIR/etc/cloud/cloud.cfg.d/99-ironstone.cfg" > /dev/null
datasource_list: [ NoCloud, None ]
datasource:
  NoCloud:
    fs_label: null
    seedfrom: /var/lib/cloud/seed/nocloud/
EOF

# Create ds-identify.cfg to force NoCloud datasource
# Format: key: value (one per line)
# datasource: forces ds-identify to use this datasource without detection
# See: https://github.com/canonical/cloud-init/blob/main/tools/ds-identify
cat <<EOF | sudo tee "$MOUNT_DIR/etc/cloud/ds-identify.cfg" > /dev/null
datasource: NoCloud
EOF

# Copy bootstrap script
sudo cp "$CLOUD_INIT_DIR/init.sh" "$MOUNT_DIR/usr/local/bin/ironstone-init.sh"
sudo chmod 755 "$MOUNT_DIR/usr/local/bin/ironstone-init.sh"

# Enable cloud-init services (chroot install skips this)
echo "Enabling cloud-init services..."
sudo mkdir -p "$MOUNT_DIR/etc/systemd/system/cloud-init.target.wants"
sudo mkdir -p "$MOUNT_DIR/etc/systemd/system/cloud-config.target.wants"
sudo mkdir -p "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants"

# Cloud-init services
sudo ln -sf /usr/lib/systemd/system/cloud-init-local.service \
    "$MOUNT_DIR/etc/systemd/system/cloud-init.target.wants/cloud-init-local.service"
sudo ln -sf /usr/lib/systemd/system/cloud-init.service \
    "$MOUNT_DIR/etc/systemd/system/cloud-init.target.wants/cloud-init.service" 2>/dev/null || \
sudo ln -sf /usr/lib/systemd/system/cloud-init-main.service \
    "$MOUNT_DIR/etc/systemd/system/cloud-init.target.wants/cloud-init-main.service"
sudo ln -sf /usr/lib/systemd/system/cloud-init-network.service \
    "$MOUNT_DIR/etc/systemd/system/cloud-init.target.wants/cloud-init-network.service"
sudo ln -sf /usr/lib/systemd/system/cloud-config.service \
    "$MOUNT_DIR/etc/systemd/system/cloud-init.target.wants/cloud-config.service"
sudo ln -sf /usr/lib/systemd/system/cloud-final.service \
    "$MOUNT_DIR/etc/systemd/system/cloud-init.target.wants/cloud-final.service"

# Cloud-init target in multi-user
sudo ln -sf /usr/lib/systemd/system/cloud-init.target \
    "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants/cloud-init.target"

# -----------------------------------------------------------------------------
# Install k3s binary
# -----------------------------------------------------------------------------
echo "Installing k3s ${K3S_VERSION}..."
K3S_BINARY="${CACHE_DIR}/k3s-${K3S_VERSION}-arm64"

if [[ ! -f "$K3S_BINARY" ]]; then
    curl -Lo "$K3S_BINARY" \
        "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-arm64"
fi

sudo cp "$K3S_BINARY" "$MOUNT_DIR/usr/local/bin/k3s"
sudo chmod 755 "$MOUNT_DIR/usr/local/bin/k3s"
sudo chown root:root "$MOUNT_DIR/usr/local/bin/k3s"

# Create symlinks
sudo ln -sf k3s "$MOUNT_DIR/usr/local/bin/kubectl"
sudo ln -sf k3s "$MOUNT_DIR/usr/local/bin/crictl"
sudo ln -sf k3s "$MOUNT_DIR/usr/local/bin/ctr"

# -----------------------------------------------------------------------------
# Install Ironstone configuration (for cloud-init to use)
# -----------------------------------------------------------------------------
echo "Installing Ironstone configuration..."

# Create ironstone config directory with build-time variables
# Cloud-init will source this to render templates
sudo mkdir -p "$MOUNT_DIR/etc/ironstone"
cat <<EOF | sudo tee "$MOUNT_DIR/etc/ironstone/config" > /dev/null
# Ironstone build-time configuration
# Sourced by cloud-init to render templates
K3S_VIP="${K3S_VIP}"
NFS_SERVER="${NFS_SERVER}"
NFS_SHARE="${NFS_SHARE}"
EOF
sudo chmod 644 "$MOUNT_DIR/etc/ironstone/config"

# K3s config directory (config.yaml will be rendered by cloud-init from template)
# The template is already in the cloud-init user-data at /etc/rancher/k3s/config.yaml.template
sudo mkdir -p "$MOUNT_DIR/etc/rancher/k3s"

# -----------------------------------------------------------------------------
# Copy k3s-node-ip.sh script
# -----------------------------------------------------------------------------
# Note: k3s-init.sh, k3s.service, modules, and sysctl configs come from cloud-init user-data
# We only need k3s-node-ip.sh here as it's called by k3s.service
cat <<'NODEIPEOF' | sudo tee "$MOUNT_DIR/usr/local/bin/k3s-node-ip.sh" > /dev/null
#!/bin/bash
# Inject node-ip into k3s config if not already set
set -euo pipefail

CONFIG_FILE="/etc/rancher/k3s/config.yaml"

# Get node IP from routing table
NODE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)

# Fallback to first IP from hostname
if [ -z "$NODE_IP" ]; then
    NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
fi

# Only add if we have an IP and config exists and node-ip not already set
if [ -n "$NODE_IP" ] && [ -f "$CONFIG_FILE" ]; then
    if ! grep -qE '^\s*node-ip:' "$CONFIG_FILE"; then
        echo "" >> "$CONFIG_FILE"
        echo "node-ip: $NODE_IP" >> "$CONFIG_FILE"
        echo "Added node-ip: $NODE_IP to $CONFIG_FILE"
    else
        echo "node-ip already configured in $CONFIG_FILE"
    fi
else
    echo "Skipping node-ip injection (IP=$NODE_IP, config exists=$(test -f "$CONFIG_FILE" && echo yes || echo no))"
fi
NODEIPEOF
sudo chmod 755 "$MOUNT_DIR/usr/local/bin/k3s-node-ip.sh"

# -----------------------------------------------------------------------------
# Install kernel modules configuration
# -----------------------------------------------------------------------------
echo "Installing kernel modules configuration..."
sudo mkdir -p "$MOUNT_DIR/etc/modules-load.d"
cat <<EOF | sudo tee "$MOUNT_DIR/etc/modules-load.d/k8s-modules.conf" > /dev/null
overlay
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
iscsi_tcp
EOF

# -----------------------------------------------------------------------------
# Install sysctl configuration
# -----------------------------------------------------------------------------
echo "Installing sysctl configuration..."
sudo mkdir -p "$MOUNT_DIR/etc/sysctl.d"
cat <<EOF | sudo tee "$MOUNT_DIR/etc/sysctl.d/99-k8s.conf" > /dev/null
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF

# -----------------------------------------------------------------------------
# Install SSH hardening configuration
# -----------------------------------------------------------------------------
echo "Installing SSH hardening configuration..."
sudo mkdir -p "$MOUNT_DIR/etc/ssh/sshd_config.d"
cat <<EOF | sudo tee "$MOUNT_DIR/etc/ssh/sshd_config.d/99-harden.conf" > /dev/null
PasswordAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
EOF

# -----------------------------------------------------------------------------
# Install NVMe rescan hook for Crucial P310 drives
# -----------------------------------------------------------------------------
echo "Installing NVMe rescan initramfs hook..."
sudo mkdir -p "$MOUNT_DIR/etc/initramfs-tools/scripts/local-premount"
cat <<'NVMEHOOK' | sudo tee "$MOUNT_DIR/etc/initramfs-tools/scripts/local-premount/nvme-rescan" > /dev/null
#!/bin/sh
# Force NVMe namespace rescan for drives that do not auto-enumerate
# Required for: Crucial CT1000P310SSD8 (firmware VACR001)

PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac

if [ -e /sys/class/nvme/nvme0 ] && [ ! -b /dev/nvme0n1 ]; then
    echo "NVMe rescan..."
    echo 1 > /sys/class/nvme/nvme0/rescan_controller
    for i in 1 2 3 4 5; do [ -b /dev/nvme0n1 ] && break; sleep 1; done
fi
NVMEHOOK
sudo chmod 755 "$MOUNT_DIR/etc/initramfs-tools/scripts/local-premount/nvme-rescan"

# Rebuild initramfs to include the hook
echo "Rebuilding initramfs..."
sudo mount --bind /dev "$MOUNT_DIR/dev"
sudo mount --bind /dev/pts "$MOUNT_DIR/dev/pts"
sudo mount -t proc proc "$MOUNT_DIR/proc"
sudo mount -t sysfs sysfs "$MOUNT_DIR/sys"
sudo chroot "$MOUNT_DIR" /bin/bash -c "update-initramfs -u -k all"
sudo umount "$MOUNT_DIR/sys" || true
sudo umount "$MOUNT_DIR/proc" || true
sudo umount "$MOUNT_DIR/dev/pts" || true
sudo umount "$MOUNT_DIR/dev" || true

# -----------------------------------------------------------------------------
# Clean up for gold image
# -----------------------------------------------------------------------------
echo "Cleaning up for gold image..."

# Clear cloud-init state
sudo rm -rf "$MOUNT_DIR/var/lib/cloud/instance"
sudo rm -rf "$MOUNT_DIR/var/lib/cloud/instances"
sudo rm -rf "$MOUNT_DIR/var/lib/cloud/data"
sudo rm -rf "$MOUNT_DIR/var/lib/cloud/sem"

# Clear machine-id
sudo rm -f "$MOUNT_DIR/etc/machine-id"
sudo touch "$MOUNT_DIR/etc/machine-id"

# Clear hostname
echo "" | sudo tee "$MOUNT_DIR/etc/hostname" > /dev/null

# Remove SSH host keys
sudo rm -f "$MOUNT_DIR/etc/ssh/ssh_host_"*

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo "Unmounting..."
[[ -n "$BOOT_PART" ]] && sudo umount "$MOUNT_DIR/boot"
sudo umount "$MOUNT_DIR"
sudo losetup -d "$LOOP_DEV"
rmdir "$MOUNT_DIR"
unset MOUNT_DIR LOOP_DEV

echo "========================================"
echo "Build Complete!"
echo "========================================"
echo ""
echo "Image: ${BUILD_DIR}/${ARTIFACT_NAME}"
echo ""
echo "To copy to macOS:"
echo "  limactl copy ironstone:${BUILD_DIR}/${ARTIFACT_NAME} ~/Downloads/"
echo ""
echo "To flash:"
echo "  sudo dd if=~/Downloads/${ARTIFACT_NAME} of=/dev/diskN bs=4M status=progress"
echo "========================================"
