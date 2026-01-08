#!/bin/bash
set -e

# =============================================================================
# Armbian Image Customization Script
# =============================================================================
# This script runs during Armbian image build (in chroot).
# It handles IMAGE-LEVEL tasks only. Per-boot configuration is in cloud-init.
#
# What belongs HERE (build-time):
#   - Installing cloud-init and minimal deps for first boot
#   - Disabling Armbian-specific features (ZRAM, OOBE)
#   - Cleaning state for gold image (machine-id, cloud-init, SSH keys)
#   - Locking root account
#   - K3s binary installation and airgap images
#   - Syncing overlay files
#
# What belongs in CLOUD-INIT (first boot):
#   - Package installation
#   - User creation (pi)
#   - Locale/timezone configuration
#   - SSH key fetching
#   - Service enablement
#   - K3s config rendering and startup
# =============================================================================

echo "=== Armbian Image Customization ==="

# Install only cloud-init and essential boot dependencies
# All other packages are installed by cloud-init on first boot
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    cloud-init \
    curl \
    nfs-common

# Disable ZRAM/Swap for Kubernetes compatibility (REQ-SYSTEM-005)
# This MUST be done at image build time, not cloud-init
echo "Disabling ZRAM/Swap..."
if dpkg -l | grep -q zram; then
    DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge armbian-zram-config zram-tools || true
fi
rm -f /etc/default/armbian-zram-config
rm -f /etc/default/zramswap
sed -i '/swap/d' /etc/fstab

# Sync overlay to root
# This ensures all files injected into userpatches/overlay are moved to their final destinations
if [ -d /tmp/overlay ]; then
    echo "Syncing overlay to / ..."
    rsync -av /tmp/overlay/ /
fi

# =============================================================================
# Gold Image Preparation (clean state for cloning)
# =============================================================================

echo "Preparing gold image..."

# Clean Cloud-init state so it runs on first boot
rm -rf /var/lib/cloud/instance
rm -rf /var/lib/cloud/instances
rm -rf /var/lib/cloud/data

# Clean Machine ID (will be regenerated on first boot)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

# Clean Hostname (cloud-init will set from MAC)
truncate -s 0 /etc/hostname

# Clean SSH Host Keys (will be regenerated on first boot)
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# =============================================================================
# Security Hardening (image-level)
# =============================================================================

echo "Applying security hardening..."

# Lock root account - no password, no login
passwd -l root

# Disable Armbian first-boot wizard (OOBE)
rm -f /root/.not_logged_in_yet
touch /root/.config_done

# =============================================================================
# K3s Binary and Airgap Images (build-time download)
# =============================================================================

# Set permissions on overlay files
chmod +x /usr/local/bin/ironstone-init.sh 2>/dev/null || true
chmod +x /usr/local/bin/k3s-init.sh 2>/dev/null || true
chmod +x /usr/local/bin/k3s-node-ip.sh 2>/dev/null || true

# K3s binary setup
if [ -f /usr/local/bin/k3s ]; then
    echo "K3s binary present"
    chmod +x /usr/local/bin/k3s
    chown root:root /usr/local/bin/k3s
    ln -sf k3s /usr/local/bin/kubectl
    ln -sf k3s /usr/local/bin/crictl
    ln -sf k3s /usr/local/bin/ctr
else
    echo "Warning: K3s binary not found in overlay"
fi

# K3s config directory permissions
mkdir -p /etc/rancher/k3s
chmod 0755 /etc/rancher/k3s

# Pre-load K3s Airgap Images
K3S_VERSION="v1.31.4+k3s1"
AIRGAP_IMAGE_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}/k3s-airgap-images-arm64.tar"
IMAGES_DIR="/var/lib/rancher/k3s/agent/images"

echo "Downloading K3s airgap images..."
mkdir -p "$IMAGES_DIR"
if [ ! -f "$IMAGES_DIR/k3s-airgap-images-arm64.tar" ]; then
    curl -L -o "$IMAGES_DIR/k3s-airgap-images-arm64.tar" "$AIRGAP_IMAGE_URL"
fi

# Rebuild initramfs to include NVMe rescan hook
echo "Rebuilding initramfs..."
update-initramfs -u -k all

echo "=== Image customization complete ==="
