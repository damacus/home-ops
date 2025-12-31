#!/bin/bash
set -euo pipefail

# verify-image.sh - Verify Armbian image meets requirements
# This script uses Docker to mount and verify the built image (macOS compatible)

IMAGE_PATH="${1:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0

log_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASS_COUNT++))
}

log_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAIL_COUNT++))
}

log_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# Check if image path provided
if [ -z "$IMAGE_PATH" ]; then
    echo "Usage: $0 <path-to-image.img>"
    echo "Example: $0 armbian-build-repo/output/images/Armbian-*.img"
    exit 1
fi

# Check if image exists
if [ ! -f "$IMAGE_PATH" ]; then
    log_fail "Image file not found: $IMAGE_PATH"
    exit 1
fi

# Get absolute path
IMAGE_PATH=$(cd "$(dirname "$IMAGE_PATH")" && pwd)/$(basename "$IMAGE_PATH")

log_info "Verifying image: $IMAGE_PATH"
echo ""

# Use Docker to mount and inspect the image
log_info "Starting Docker container to mount image..."
echo ""

# Run verification inside Docker container with ext4 support
docker run --rm --privileged \
    -v "$IMAGE_PATH:/image.img:ro" \
    ubuntu:noble \
    bash -c '
set -o pipefail

# Colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

PASS_COUNT=0
FAIL_COUNT=0

log_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASS_COUNT++))
}

log_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAIL_COUNT++))
}

log_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# Install required tools
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq fdisk kpartx mount >/dev/null 2>&1

# Setup loop device and create partition mappings
LOOP_DEVICE=$(losetup -f --show /image.img)
kpartx -av "$LOOP_DEVICE"

# Wait for partition device
sleep 2

# Get the mapper device (kpartx creates /dev/mapper/loopXpY)
LOOP_NAME=$(basename "$LOOP_DEVICE")
PARTITION_DEVICE="/dev/mapper/${LOOP_NAME}p1"

# Mount the partition
MOUNT_POINT="/mnt/verify"
mkdir -p "$MOUNT_POINT"
mount -o ro "$PARTITION_DEVICE" "$MOUNT_POINT"

echo ""
echo "=== Verification Results ==="
echo ""

# REQ-K3S-001: K3s binary installed
if [ -f "$MOUNT_POINT/usr/local/bin/k3s" ]; then
    K3S_VERSION=$(chroot "$MOUNT_POINT" /usr/local/bin/k3s --version 2>&1 | head -n1 || echo "unknown")
    log_pass "K3s binary present: $K3S_VERSION"
else
    log_fail "K3s binary missing at /usr/local/bin/k3s"
fi

# REQ-K3S-002: K3s airgap images
if [ -f "$MOUNT_POINT/var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar" ]; then
    SIZE=$(du -h "$MOUNT_POINT/var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar" | cut -f1)
    log_pass "K3s airgap images present ($SIZE)"
else
    log_fail "K3s airgap images missing"
fi

# REQ-K3S-003: Kernel headers for eBPF/Cilium
KERNEL_VERSION=$(ls "$MOUNT_POINT/lib/modules/" 2>/dev/null | head -n1 || echo "")
if [ -n "$KERNEL_VERSION" ]; then
    if [ -d "$MOUNT_POINT/usr/src/linux-headers-$KERNEL_VERSION" ] || \
       [ -d "$MOUNT_POINT/lib/modules/$KERNEL_VERSION/build" ]; then
        log_pass "Kernel headers present for $KERNEL_VERSION"
    else
        log_fail "Kernel headers missing for $KERNEL_VERSION"
    fi
else
    log_fail "No kernel modules found"
fi

# REQ-SYSTEM-001: Required packages
REQUIRED_PACKAGES=(
    "curl"
    "conntrack"
    "iptables"
    "socat"
    "cloud-init"
    "nvme-cli"
)

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if chroot "$MOUNT_POINT" dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        log_pass "Package installed: $pkg"
    else
        log_fail "Package missing: $pkg"
    fi
done

# REQ-SYSTEM-003: Timezone configuration
if [ -L "$MOUNT_POINT/etc/localtime" ]; then
    TIMEZONE=$(readlink "$MOUNT_POINT/etc/localtime" | sed "s|.*/zoneinfo/||")
    if [ "$TIMEZONE" = "Europe/London" ]; then
        log_pass "Timezone set to Europe/London"
    else
        log_fail "Timezone is $TIMEZONE, expected Europe/London"
    fi
else
    log_fail "Timezone not configured"
fi

# REQ-SYSTEM-004: Locale configuration
if grep -q "en_GB.UTF-8" "$MOUNT_POINT/etc/default/locale" 2>/dev/null; then
    log_pass "Locale configured to en_GB.UTF-8"
else
    log_fail "Locale not set to en_GB.UTF-8"
fi

# REQ-SYSTEM-005: ZRAM disabled
ZRAM_DISABLED=true
if chroot "$MOUNT_POINT" dpkg -l 2>/dev/null | grep -q "^ii.*zram"; then
    log_fail "ZRAM packages still installed"
    ZRAM_DISABLED=false
fi

if [ -f "$MOUNT_POINT/etc/default/armbian-zram-config" ]; then
    log_fail "ZRAM config file still present"
    ZRAM_DISABLED=false
fi

if $ZRAM_DISABLED; then
    log_pass "ZRAM disabled (no packages or config found)"
fi

# REQ-SYSTEM-006: Swap disabled
if grep -q "^[^#].*swap" "$MOUNT_POINT/etc/fstab" 2>/dev/null; then
    log_fail "Swap entries found in /etc/fstab"
else
    log_pass "No swap entries in /etc/fstab"
fi

# Check cloud-init configuration
if [ -f "$MOUNT_POINT/etc/cloud/cloud.cfg" ]; then
    log_pass "cloud-init configuration present"
else
    log_fail "cloud-init configuration missing"
fi

# Check systemd services
REQUIRED_SERVICES=(
    "k3s-init.service"
    "k3s.service"
)

for svc in "${REQUIRED_SERVICES[@]}"; do
    if [ -f "$MOUNT_POINT/etc/systemd/system/$svc" ]; then
        log_pass "Systemd service present: $svc"
    else
        log_fail "Systemd service missing: $svc"
    fi
done

# REQ-SECURITY-001: Root login disabled
if grep -q "^root:!" "$MOUNT_POINT/etc/shadow" 2>/dev/null || \
   grep -q "^root:\*" "$MOUNT_POINT/etc/shadow" 2>/dev/null; then
    log_pass "Root account is locked"
else
    log_fail "Root account is NOT locked"
fi

# REQ-SSH-001: SSH hardening config
if [ -f "$MOUNT_POINT/etc/ssh/sshd_config.d/99-ironstone-hardening.conf" ]; then
    if grep -q "PermitRootLogin no" "$MOUNT_POINT/etc/ssh/sshd_config.d/99-ironstone-hardening.conf"; then
        log_pass "SSH root login disabled in config"
    else
        log_fail "SSH PermitRootLogin not set to no"
    fi
else
    log_fail "SSH hardening config missing"
fi

# REQ-USER-001: Pi user exists
if grep -q "^pi:" "$MOUNT_POINT/etc/passwd" 2>/dev/null; then
    log_pass "Pi user exists"
else
    log_fail "Pi user missing"
fi

# REQ-USER-002: Pi user has sudo access
if [ -f "$MOUNT_POINT/etc/sudoers.d/pi" ]; then
    log_pass "Pi user sudoers config present"
else
    log_fail "Pi user sudoers config missing"
fi

# REQ-SCRIPT-001: Ironstone init script
if [ -x "$MOUNT_POINT/usr/local/bin/ironstone-init.sh" ]; then
    log_pass "ironstone-init.sh present and executable"
else
    log_fail "ironstone-init.sh missing or not executable"
fi

# REQ-SCRIPT-002: K3s node-ip script
if [ -x "$MOUNT_POINT/usr/local/bin/k3s-node-ip.sh" ]; then
    log_pass "k3s-node-ip.sh present and executable"
else
    log_fail "k3s-node-ip.sh missing or not executable"
fi

# REQ-K3S-004: K3s registries config
if [ -f "$MOUNT_POINT/etc/rancher/k3s/registries.yaml" ]; then
    log_pass "K3s registries.yaml present"
else
    log_fail "K3s registries.yaml missing"
fi

# REQ-K3S-005: K3s config template
if [ -f "$MOUNT_POINT/etc/rancher/k3s/config.yaml.template" ]; then
    log_pass "K3s config.yaml.template present"
else
    log_fail "K3s config.yaml.template missing"
fi

# REQ-MAINT-001: Etcd maintenance scripts (stored in /usr/local/share/ironstone/)
if [ -f "$MOUNT_POINT/usr/local/share/ironstone/etcd-maint.sh" ]; then
    log_pass "etcd-maint.sh present"
else
    log_fail "etcd-maint.sh missing"
fi

if [ -f "$MOUNT_POINT/usr/local/share/ironstone/etcd-reset.sh" ]; then
    log_pass "etcd-reset.sh present"
else
    log_fail "etcd-reset.sh missing"
fi

# Cleanup
umount "$MOUNT_POINT"
kpartx -dv "$LOOP_DEVICE"
losetup -d "$LOOP_DEVICE"

echo ""
echo "=== Summary ==="
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some checks failed. Review the output above.${NC}"
    exit 1
fi
'
