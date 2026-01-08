#!/bin/bash
set -e

# install_k3s_prereqs
# Note: Kernel headers are installed by the Armbian build system (e.g. linux-headers-vendor-rk35xx)
# We don't need to explicit install linux-headers-${BRANCH}-${BOARD} as it often has the wrong name.

echo "Installing K3s prerequisites..."
# The build environment might not have internet if it's strictly offline,
# but usually customize-image.sh runs in a chroot with net access if configured.
# Armbian provides a function to install packages: install_deb_chroot_package, or we use apt-get.

# We need to resolve the variables $BRANCH and $BOARD if they are not set,
# but usually they are available in this context.
# If strictly relying on variables passed from requirements.json, we might need to source them.
# However, this script is running inside the Armbian build context, so BOARD and BRANCH should be set.

DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    cloud-init \
    conntrack \
    curl \
    dirmngr \
    gdisk \
    gnupg \
    hdparm \
    htop \
    iptables \
    iputils-ping \
    ipvsadm \
    libseccomp2 \
    lm-sensors \
    locales \
    multipath-tools \
    net-tools \
    nfs-common \
    nvme-cli \
    open-iscsi \
    parted \
    psmisc \
    python3 \
    rsync \
    smartmontools \
    socat \
    unzip \
    util-linux \
    vim

# Configure Locale (REQ-SYSTEM-004)
echo "Generating en_GB.UTF-8 locale..."
echo "en_GB.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
# Set all locale variables consistently to avoid conflicts
update-locale LANG=en_GB.UTF-8 LANGUAGE=en_GB.UTF-8 LC_ALL=en_GB.UTF-8 LC_MESSAGES=en_GB.UTF-8

# Configure Timezone (REQ-SYSTEM-003)
echo "Setting timezone to Europe/London..."
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
echo "Europe/London" > /etc/timezone

# Disable ZRAM/Swap for Kubernetes compatibility (REQ-SYSTEM-005)
# Armbian often comes with armbian-zram-config or zram-tools
if dpkg -l | grep -q zram; then
    echo "Removing zram configuration for K3s compatibility..."
    DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge armbian-zram-config zram-tools || true
fi
# Remove ZRAM config files
rm -f /etc/default/armbian-zram-config
rm -f /etc/default/zramswap
# Ensure swap is disabled in fstab (though Armbian usually doesn't create swap partitions on SD)
sed -i '/swap/d' /etc/fstab

# Enable iscsid (REQ-STORAGE-001) and multipathd (REQ-STORAGE-002)
systemctl enable iscsid
systemctl enable multipathd

# Sync overlay to root
# This ensures all files injected into userpatches/overlay are moved to their final destinations
if [ -d /tmp/overlay ]; then
    echo "Syncing overlay to / ..."
    rsync -av /tmp/overlay/ /
fi

# Clean Cloud-init state (REQ-CLOUD-005)
echo "Cleaning cloud-init state..."
rm -rf /var/lib/cloud/instance
rm -rf /var/lib/cloud/instances
rm -rf /var/lib/cloud/data
rm -f /var/lib/cloud/instance/boot-finished

# Clean Machine ID (REQ-SYSTEM-001)
echo "Cleaning machine-id..."
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

# Clean Hostname (REQ-SYSTEM-002)
echo "Cleaning hostname..."
truncate -s 0 /etc/hostname
echo "localhost" > /etc/hostname

# Clean SSH Host Keys (REQ-SSH-003)
echo "Cleaning SSH host keys..."
rm -f /etc/ssh/ssh_host_*_key

# SSH hardening - disable password auth and root login
# Note: overlay/etc/ssh/sshd_config.d/99-security.conf also sets this
# but we ensure it here in case overlay isn't applied
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-ironstone-hardening.conf << 'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF

# Lock root account - no password, no login
echo "Locking root account..."
passwd -l root

# Disable Armbian first-boot wizard (OOBE)
# Armbian checks for /root/.not_logged_in_yet to trigger OOBE
echo "Disabling Armbian first-boot wizard..."
rm -f /root/.not_logged_in_yet

# Mark system as configured to skip Armbian's first-run scripts
touch /root/.config_done

# Create pi user for administration (REQ-USER-001)
echo "Creating pi user..."
if ! id -u pi &>/dev/null; then
    useradd -m -s /bin/bash -G adm,sudo pi
fi
# Allow passwordless sudo for pi
echo "pi ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/pi
chmod 0440 /etc/sudoers.d/pi

# Create etcd maintenance scripts in /usr/local/share/ironstone/
# Note: /home/* is excluded by Armbian's rsync, so we store scripts elsewhere
# and copy them to pi home on first boot via cloud-init or ironstone-init
echo "Creating etcd maintenance scripts..."
mkdir -p /usr/local/share/ironstone

cat > /usr/local/share/ironstone/etcd-maint.sh << 'ETCD_MAINT_EOF'
#!/bin/bash
# Description: Automates the compaction and defragmentation of the k3s embedded etcd database.
export ETCDCTL_ENDPOINTS='https://127.0.0.1:2379'
export ETCDCTL_CACERT='/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt'
export ETCDCTL_CERT='/var/lib/rancher/k3s/server/tls/etcd/server-client.crt'
export ETCDCTL_KEY='/var/lib/rancher/k3s/server/tls/etcd/server-client.key'
export ETCDCTL_API=3

run_etcdctl() {
    echo "--> Running: etcdctl $@"
    etcdctl "$@"
    if [ $? -ne 0 ]; then
        echo "ERROR: etcdctl command failed. Maintenance halted." >&2
        exit 1
    fi
}

echo "--- K3s Embedded Etcd Maintenance Started ---"
run_etcdctl endpoint health --cluster --write-out=table
run_etcdctl endpoint status --cluster --write-out=table

REV=$(run_etcdctl endpoint status --write-out fields | grep -i '"Revision"' | cut -d: -f2 | tr -d '[:space:]')
if [[ -z "$REV" ]]; then
    echo "ERROR: Failed to retrieve etcd revision." >&2
    exit 1
fi

echo "Compacting to revision $REV..."
run_etcdctl compact "$REV"
echo "Defragmenting cluster..."
run_etcdctl defrag --cluster

run_etcdctl endpoint health --cluster --write-out=table
run_etcdctl check perf
echo "--- Etcd Maintenance finished successfully. ---"
ETCD_MAINT_EOF

cat > /usr/local/share/ironstone/etcd-reset.sh << 'ETCD_RESET_EOF'
#!/bin/bash
set -euo pipefail
systemctl stop k3s
rm -rf /var/lib/rancher/k3s/server/db/etcd
systemctl start k3s
ETCD_RESET_EOF

chmod 0755 /usr/local/share/ironstone/etcd-maint.sh
chmod 0755 /usr/local/share/ironstone/etcd-reset.sh

# Set correct permissions on overlay files
echo "Setting file permissions..."
chmod +x /usr/local/bin/ironstone-init.sh 2>/dev/null || true
chmod +x /usr/local/bin/k3s-init.sh 2>/dev/null || true
chmod +x /usr/local/bin/k3s-node-ip.sh 2>/dev/null || true
chmod 0755 /home/pi/etcd-maint.sh 2>/dev/null || true
chmod 0755 /home/pi/etcd-reset.sh 2>/dev/null || true
chown -R pi:pi /home/pi 2>/dev/null || true

# Set permissions on k3s config directory
mkdir -p /etc/rancher/k3s
chmod 0755 /etc/rancher/k3s
chmod 0644 /etc/rancher/k3s/registries.yaml 2>/dev/null || true
chmod 0644 /etc/rancher/k3s/config.yaml.template 2>/dev/null || true

# inject_k3s_binary
# Move K3s binary from overlay to /usr/local/bin
# (This is technically redundant with rsync above, but explicit check doesn't hurt)
if [ -f /usr/local/bin/k3s ]; then
    echo "K3s binary present at /usr/local/bin/k3s"
    chmod +x /usr/local/bin/k3s
    chown root:root /usr/local/bin/k3s
    # Create k3s symlinks (REQ-K3S-002)
    echo "Creating k3s symlinks..."
    ln -sf k3s /usr/local/bin/kubectl
    ln -sf k3s /usr/local/bin/crictl
    ln -sf k3s /usr/local/bin/ctr
else
    echo "Warning: K3s binary not found in /usr/local/bin/k3s"
    # Fallback download if not in overlay (though requirements.json said it would download it)
    # wget https://github.com/k3s-io/k3s/releases/download/v1.31.4%2Bk3s1/k3s-arm64 -O /usr/local/bin/k3s
    # chmod +x /usr/local/bin/k3s
fi

# Pre-load K3s Airgap Images (REQ-OFFLINE-001)
# See docs.txt Section 7.3
K3S_VERSION="v1.31.4+k3s1"
AIRGAP_IMAGE_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}/k3s-airgap-images-arm64.tar"
IMAGES_DIR="/var/lib/rancher/k3s/agent/images"

echo "Downloading K3s airgap images..."
mkdir -p "$IMAGES_DIR"
if [ ! -f "$IMAGES_DIR/k3s-airgap-images-arm64.tar" ]; then
    curl -L -o "$IMAGES_DIR/k3s-airgap-images-arm64.tar" "$AIRGAP_IMAGE_URL"
    echo "K3s airgap images placed in $IMAGES_DIR"
fi

# Rebuild initramfs to include NVMe rescan hook
# Required for Crucial CT1000P310SSD8 drives that don't auto-enumerate namespace
echo "Rebuilding initramfs with NVMe rescan hook..."
update-initramfs -u -k all

# Clean up overlay if needed, though Armbian handles some cleanup.
