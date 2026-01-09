#!/bin/bash
set -euo pipefail

# Directory of this script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONING_DIR="$(dirname "${DIR}")"
ARMBIAN_REPO="https://github.com/armbian/build"
ARMBIAN_BRANCH="main"
BUILD_DIR="${DIR}/armbian-build-repo"

# Source provisioning configuration
if [[ -f "${PROVISIONING_DIR}/config.env" ]]; then
    echo "Loading configuration from config.env..."
    source "${PROVISIONING_DIR}/config.env"
else
    echo "ERROR: ${PROVISIONING_DIR}/config.env not found"
    exit 1
fi

# Ensure we are in a clean state or clone if missing
if [[ ! -d "${BUILD_DIR}" ]]; then
    echo "Cloning Armbian build framework..."
    git clone --depth 1 --branch "${ARMBIAN_BRANCH}" "${ARMBIAN_REPO}" "${BUILD_DIR}"
fi

# Copy userpatches
echo "Copying userpatches to build directory..."
rm -rf "${BUILD_DIR}/userpatches"
cp -r "${DIR}/userpatches" "${BUILD_DIR}/"

# Generate /etc/ironstone/config from config.env values
echo "Generating ironstone config..."
mkdir -p "${BUILD_DIR}/userpatches/overlay/etc/ironstone"
cat > "${BUILD_DIR}/userpatches/overlay/etc/ironstone/config" << EOF
NFS_SERVER="${NFS_SERVER}"
NFS_SHARE="${NFS_SHARE}"
K3S_VIP="${K3S_VIP}"
EOF

# Download K3s binary if defined in requirements (simulating the python driver logic for now)
# In a real full impl, a python script would parse requirements.json and do this.
# For now, we manually implement the "download_file" task from stage_3 since we are bootstrapping.
K3S_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-arm64"
K3S_DEST="${BUILD_DIR}/userpatches/overlay/usr/local/bin/k3s"

echo "Downloading K3s binary..."
mkdir -p "$(dirname "${K3S_DEST}")"
if [[ ! -f "${K3S_DEST}" ]]; then
    curl -L -o "${K3S_DEST}" "${K3S_URL}"
    chmod +x "${K3S_DEST}"
fi

# Execute Build
echo "Starting Armbian Build..."
cd "${BUILD_DIR}"

# Force standard terminal type to avoid build script issues with modern emulators (Ghostty/WezTerm)
export TERM=xterm-256color

# Using "vendor" branch (kernel 6.1) for Rock 5B Plus
# - Vendor kernel provides stable NPU support via rknpu2 driver
# - Noble (Ubuntu 24.04) userspace for modern packages
# - Cilium eBPF requirements (CONFIG_DEBUG_INFO_BTF, BPF_SYSCALL, CGROUP_BPF) are enabled
./compile.sh \
    BOARD="rock-5b-plus" \
    BRANCH="vendor" \
    RELEASE="noble" \
    BUILD_MINIMAL="yes" \
    BUILD_DESKTOP="no" \
    KERNEL_CONFIGURE="no" \
    COMPRESS_OUTPUTIMAGE="sha,gpg,img" \
    FIXED_IMAGE_SIZE="3072" \
    INSTALL_HEADERS="yes" \
    ENABLE_EXTENSIONS="nvme-rescan"

echo "Build complete. Artifacts are in ${BUILD_DIR}/output/images/"
