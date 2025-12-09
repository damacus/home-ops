#!/bin/bash
# =============================================================================
# Simple Armbian Image Builder for Rock 5B+
# =============================================================================
# MVP: Build a golden image with extra packages pre-installed
# Usage: ./build.sh [board]
#   board: rock-5b-plus (default), rock-5b
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/armbian-build"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
ARMBIAN_REPO="https://github.com/armbian/build.git"
ARMBIAN_BRANCH="main"
BOARD="${1:-rock-5b-plus}"
RELEASE="bookworm"  # Using stable Bookworm; change to "trixie" for testing
BRANCH="vendor"     # vendor kernel for best hardware support
BUILD_MINIMAL="yes" # Minimal image without extras
BUILD_DESKTOP="no"
KERNEL_CONFIGURE="no"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

check_dependencies() {
    log "Checking dependencies..."

    local missing=()
    for cmd in git docker; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Missing required tools: ${missing[*]}"
        echo "Please install them and try again."
        exit 1
    fi

    if ! docker info &>/dev/null; then
        echo "Error: Docker daemon is not running"
        exit 1
    fi

    log "All dependencies satisfied."
}

clone_armbian() {
    if [[ -d "${BUILD_DIR}" ]]; then
        log "Armbian build directory exists, updating..."
        git -C "${BUILD_DIR}" fetch origin
        git -C "${BUILD_DIR}" reset --hard "origin/${ARMBIAN_BRANCH}"
    else
        log "Cloning Armbian build system..."
        git clone --depth 1 --branch "${ARMBIAN_BRANCH}" "${ARMBIAN_REPO}" "${BUILD_DIR}"
    fi
}

setup_userpatches() {
    log "Setting up userpatches..."

    local userpatches_dir="${BUILD_DIR}/userpatches"
    mkdir -p "${userpatches_dir}"

    # Copy our lib.config with additional packages
    cp "${SCRIPT_DIR}/lib.config" "${userpatches_dir}/lib.config"

    log "Userpatches configured."
}

build_image() {
    log "Starting Armbian build..."
    log "Board: ${BOARD}"
    log "Branch: ${BRANCH}"
    log "Release: ${RELEASE}"

    cd "${BUILD_DIR}"

    # Run the build using Docker (recommended method)
    ./compile.sh \
        BOARD="${BOARD}" \
        BRANCH="${BRANCH}" \
        RELEASE="${RELEASE}" \
        BUILD_MINIMAL="${BUILD_MINIMAL}" \
        BUILD_DESKTOP="${BUILD_DESKTOP}" \
        KERNEL_CONFIGURE="${KERNEL_CONFIGURE}" \
        COMPRESS_OUTPUTIMAGE="sha,xz"

    log "Build complete!"
}

copy_output() {
    log "Copying output images..."
    mkdir -p "${OUTPUT_DIR}"

    # Find and copy the built image
    find "${BUILD_DIR}/output/images" -name "*.img.xz" -exec cp {} "${OUTPUT_DIR}/" \;
    find "${BUILD_DIR}/output/images" -name "*.img.xz.sha" -exec cp {} "${OUTPUT_DIR}/" \;

    log "Images copied to: ${OUTPUT_DIR}"
    ls -la "${OUTPUT_DIR}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log "=========================================="
    log "Armbian Golden Image Builder"
    log "=========================================="

    check_dependencies
    clone_armbian
    setup_userpatches
    build_image
    copy_output

    log "=========================================="
    log "Build Complete!"
    log "Output: ${OUTPUT_DIR}"
    log "=========================================="
}

main "$@"
