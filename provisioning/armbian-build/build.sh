#!/bin/bash
set -euo pipefail

# Directory of this script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARMBIAN_REPO="https://github.com/armbian/build"
ARMBIAN_BRANCH="main"
BUILD_DIR="${DIR}/armbian-build-repo"

# Ensure we are in a clean state or clone if missing
if [ ! -d "$BUILD_DIR" ]; then
    echo "Cloning Armbian build framework..."
    git clone --depth 1 --branch "$ARMBIAN_BRANCH" "$ARMBIAN_REPO" "$BUILD_DIR"
fi

# Copy userpatches
echo "Copying userpatches to build directory..."
rm -rf "$BUILD_DIR/userpatches"
cp -r "$DIR/userpatches" "$BUILD_DIR/"

K3S_VERSION="v1.33.2+k3s1"

# Download K3s binary if defined in requirements (simulating the python driver logic for now)
# In a real full impl, a python script would parse requirements.json and do this.
# For now, we manually implement the "download_file" task from stage_3 since we are bootstrapping.
K3S_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-arm64"
K3S_DEST="$BUILD_DIR/userpatches/overlay/usr/local/bin/k3s"

echo "Downloading K3s binary..."
mkdir -p "$(dirname "$K3S_DEST")"
if [ ! -f "$K3S_DEST" ]; then
    curl -L -o "$K3S_DEST" "$K3S_URL"
    chmod +x "$K3S_DEST"
fi

# Execute Build
echo "Starting Armbian Build..."
cd "$BUILD_DIR"

# Force standard terminal type to avoid build script issues with modern emulators (Ghostty/WezTerm)
export TERM=xterm-256color

# NOTE: Using "edge" branch for Rock 5B Plus - this board requires newer kernel
# and BSP components only available in edge. The vendor/current branches don't
# have full support for this hardware yet.
./compile.sh \
    BOARD="rock-5b-plus" \
    BRANCH="edge" \
    RELEASE="noble" \
    BUILD_MINIMAL="yes" \
    BUILD_DESKTOP="no" \
    KERNEL_CONFIGURE="no" \
    COMPRESS_OUTPUTIMAGE="sha,gpg,img" \
    FIXED_IMAGE_SIZE="3072" \
    INSTALL_HEADERS="yes"

echo "Build complete. Artifacts are in $BUILD_DIR/output/images/"
