#!/bin/bash
set -euo pipefail

# =============================================================================
# Ironstone Zero-Touch Provisioning Build Script
# =============================================================================
# NOTE: Docker-based builds are currently broken on ARM64 Mac due to binfmt_misc
# issues. Use build-native.sh with Lima VM instead:
#
#   limactl shell ironstone bash -c "cd $(pwd) && ./build-native.sh rpi5 gold"
#
# This script is retained for disk space management utilities.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROVISIONING_DIR="/workspace/provisioning"

# -----------------------------------------------------------------------------
# Load Configuration
# -----------------------------------------------------------------------------
load_config() {
    local config_file="${SCRIPT_DIR}/config.env"
    local local_config="${SCRIPT_DIR}/config.env.local"

    if [[ -f "$local_config" ]]; then
        echo "Loading local configuration from config.env.local"
        # shellcheck source=/dev/null
        source "$local_config"
    elif [[ -f "$config_file" ]]; then
        echo "Loading configuration from config.env"
        # shellcheck source=/dev/null
        source "$config_file"
    else
        echo "Error: No configuration file found."
        echo "Expected: ${config_file} or ${local_config}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: ./build.sh [OPTIONS] <board> <type>

Arguments:
  board     Target board: rpi5 | rock5b
  type      Image type: gold | flasher

Options:
  -h, --help        Show this help message
  -n, --dry-run     Validate configuration without building
  -c, --clean       Remove old build artifacts before building
  --clean-cache     Remove Packer cache (downloaded base images)
  --clean-all       Remove both build artifacts and cache
  --disk-usage      Show current disk usage and exit

Environment:
  K3S_TOKEN         Required for gold images. Can be set via:
                    - Environment variable
                    - File at ~/.secrets/k3s_token
                    - File at ./secrets/k3s_token
  MIN_DISK_SPACE_GB Minimum free disk space required (default: 15)

Examples:
  ./build.sh rpi5 gold
  ./build.sh --dry-run rock5b flasher
  ./build.sh --clean rpi5 gold
  ./build.sh --clean-all              # Free up disk space
  ./build.sh --disk-usage             # Check current usage

EOF
    exit "${1:-0}"
}

# -----------------------------------------------------------------------------
# Validation Functions
# -----------------------------------------------------------------------------
validate_docker() {
    if [[ "${SKIP_DOCKER_VALIDATION:-false}" == "true" ]]; then
        echo "Skipping Docker validation (SKIP_DOCKER_VALIDATION=true)"
        return 0
    fi

    if ! command -v docker &>/dev/null; then
        echo "Error: Docker is not installed or not in PATH"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        echo "Error: Docker daemon is not running"
        exit 1
    fi
}

validate_secrets() {
    local image_type="$1"

    # Flasher images don't need K3S_TOKEN
    if [[ "$image_type" == "flasher" ]]; then
        return 0
    fi

    # Check for K3S_TOKEN in order of precedence
    if [[ -n "${K3S_TOKEN:-}" ]]; then
        echo "Using K3S_TOKEN from environment variable"
        return 0
    fi

    if [[ -n "${K3S_TOKEN_FILE:-}" && -f "${K3S_TOKEN_FILE}" ]]; then
        echo "Loading K3S_TOKEN from ${K3S_TOKEN_FILE}"
        K3S_TOKEN=$(cat "${K3S_TOKEN_FILE}")
        export K3S_TOKEN
        return 0
    fi

    local allow_system_paths="${K3S_TOKEN_ALLOW_SYSTEM_PATHS:-true}"

    local secret_paths=(
        "${HOME}/.secrets/k3s_token"
        "${SCRIPT_DIR}/secrets/k3s_token"
    )

    if [[ "${allow_system_paths}" == "true" ]]; then
        secret_paths+=("/Volumes/csi_nfs/provisioning/token")
    fi

    for path in "${secret_paths[@]}"; do
        if [[ -f "$path" ]]; then
            echo "Loading K3S_TOKEN from $path"
            K3S_TOKEN=$(cat "$path")
            export K3S_TOKEN
            return 0
        fi
    done

    echo "Error: K3S_TOKEN is required for gold images."
    echo "Set it via:"
    echo "  - Environment variable: export K3S_TOKEN='your-token'"
    echo "  - Secret file: ~/.secrets/k3s_token"
    echo "  - Secret file: ${SCRIPT_DIR}/secrets/k3s_token"
    exit 1
}

validate_network() {
    if [[ "${SKIP_NETWORK_VALIDATION:-false}" == "true" ]]; then
        echo "Skipping network validation (SKIP_NETWORK_VALIDATION=true)"
        return 0
    fi

    local nfs_server="${NFS_SERVER:-192.168.1.243}"

    echo "Checking network connectivity to NFS server ($nfs_server)..."
    if ! ping -c 1 -W 2 "$nfs_server" &>/dev/null; then
        echo "Warning: Cannot reach NFS server at $nfs_server"
        echo "Gold image upload may fail."
    else
        echo "NFS server is reachable."
    fi
}

# -----------------------------------------------------------------------------
# Build Artifact Naming
# -----------------------------------------------------------------------------
get_artifact_name() {
    local board="$1"
    local type="$2"

    if [[ "${VERSIONED_ARTIFACTS:-false}" == "true" ]]; then
        local git_sha
        local timestamp
        git_sha=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        timestamp=$(date +%Y%m%d-%H%M%S)
        echo "${board}-${type}-${git_sha}-${timestamp}.img"
    else
        echo "${board}-${type}.img"
    fi
}

# -----------------------------------------------------------------------------
# Clean Build Artifacts
# -----------------------------------------------------------------------------
clean_builds() {
    local builds_dir="${SCRIPT_DIR}/packer/builds"
    if [[ -d "$builds_dir" ]]; then
        echo "Cleaning old build artifacts..."
        rm -rf "${builds_dir:?}"/*
        echo "Build directory cleaned."
    fi
}

# -----------------------------------------------------------------------------
# Clean Packer Cache
# -----------------------------------------------------------------------------
clean_cache() {
    local cache_dir="${SCRIPT_DIR}/packer/.packer_cache"
    if [[ -d "$cache_dir" ]]; then
        echo "Cleaning Packer cache..."
        rm -rf "${cache_dir:?}"/*
        echo "Packer cache cleaned."
    fi
}

# -----------------------------------------------------------------------------
# Check Available Disk Space
# -----------------------------------------------------------------------------
check_disk_space() {
    local min_space_gb="${MIN_DISK_SPACE_GB:-15}"
    local packer_dir="${SCRIPT_DIR}/packer"

    # Get available space in GB
    local available_gb
    if [[ "$(uname)" == "Darwin" ]]; then
        available_gb=$(df -g "$packer_dir" | awk 'NR==2 {print $4}')
    else
        available_gb=$(df -BG "$packer_dir" | awk 'NR==2 {print $4}' | tr -d 'G')
    fi

    echo "Available disk space: ${available_gb}GB (minimum required: ${min_space_gb}GB)"

    if [[ "$available_gb" -lt "$min_space_gb" ]]; then
        echo "WARNING: Low disk space!"
        echo "Packer builds typically need 10-15GB of free space."
        echo ""
        echo "To free space, run:"
        echo "  ./build.sh --clean-all"
        echo ""
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# -----------------------------------------------------------------------------
# Show Disk Usage
# -----------------------------------------------------------------------------
show_disk_usage() {
    echo "Disk usage for provisioning:"
    echo ""

    local builds_dir="${SCRIPT_DIR}/packer/builds"
    local cache_dir="${SCRIPT_DIR}/packer/.packer_cache"

    if [[ -d "$builds_dir" ]]; then
        local builds_size
        builds_size=$(du -sh "$builds_dir" 2>/dev/null | cut -f1)
        echo "  Build artifacts:  ${builds_size:-0}"
    fi

    if [[ -d "$cache_dir" ]]; then
        local cache_size
        cache_size=$(du -sh "$cache_dir" 2>/dev/null | cut -f1)
        echo "  Packer cache:     ${cache_size:-0}"
    fi

    echo ""
}

# -----------------------------------------------------------------------------
# Main Build Function
# -----------------------------------------------------------------------------
build() {
    local target_board="$1"
    local image_type="$2"
    local artifact_name

    artifact_name=$(get_artifact_name "$target_board" "$image_type")

    echo "========================================"
    echo "Ironstone Build Pipeline"
    echo "========================================"
    echo "Target Board:    $target_board"
    echo "Image Type:      $image_type"
    echo "Artifact Name:   $artifact_name"
    echo "K3s Version:     ${K3S_VERSION:-latest}"
    echo "Builder Image:   ghcr.io/michalfita/packer-plugin-cross:${PACKER_CROSS_VERSION:-latest}"
    echo "========================================"

    # Create secrets directory in container-accessible location
    local secrets_mount=""
    if [[ -n "${K3S_TOKEN:-}" ]]; then
        local tmp_secrets
        tmp_secrets=$(mktemp -d)
        echo "$K3S_TOKEN" > "${tmp_secrets}/k3s_token"
        chmod 600 "${tmp_secrets}/k3s_token"
        secrets_mount="-v ${tmp_secrets}:/run/secrets:ro"
        trap "rm -rf ${tmp_secrets}" EXIT
    fi

    # Run Packer build using docker compose
    # Export variables for docker compose to use
    export TARGET_BOARD="$target_board"
    export IMAGE_TYPE="$image_type"
    export ARTIFACT_NAME="$artifact_name"

    pushd "$SCRIPT_DIR" >/dev/null
    docker compose run --rm --build packer-build
    popd >/dev/null

    echo "========================================"
    echo "Build Complete!"
    echo "Artifact: ${SCRIPT_DIR}/packer/builds/${artifact_name}"
    echo "========================================"
}

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
DRY_RUN=false
CLEAN=false
CLEAN_CACHE=false
CLEAN_ALL=false
DISK_USAGE_ONLY=false
TARGET_BOARD=""
IMAGE_TYPE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -c|--clean)
            CLEAN=true
            shift
            ;;
        --clean-cache)
            CLEAN_CACHE=true
            shift
            ;;
        --clean-all)
            CLEAN_ALL=true
            shift
            ;;
        --disk-usage)
            DISK_USAGE_ONLY=true
            shift
            ;;
        rpi5|rock5b)
            TARGET_BOARD="$1"
            shift
            ;;
        gold|flasher)
            IMAGE_TYPE="$1"
            shift
            ;;
        *)
            echo "Error: Unknown argument '$1'"
            usage
            ;;
    esac
done

# Handle disk usage only
if [[ "$DISK_USAGE_ONLY" == "true" ]]; then
    show_disk_usage
    exit 0
fi

# Handle clean-all (no build required)
if [[ "$CLEAN_ALL" == "true" ]]; then
    clean_builds
    clean_cache
    echo "All build artifacts and cache cleaned."
    exit 0
fi

# Handle clean-cache only (no build required)
if [[ "$CLEAN_CACHE" == "true" && -z "$TARGET_BOARD" ]]; then
    clean_cache
    exit 0
fi

# Handle clean only (no build required)
if [[ "$CLEAN" == "true" && -z "$TARGET_BOARD" && -z "$IMAGE_TYPE" ]]; then
    clean_builds
    exit 0
fi

# Validate required arguments for build
if [[ -z "$TARGET_BOARD" || -z "$IMAGE_TYPE" ]]; then
    echo "Error: Both board and type are required."
    usage 1
fi

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------
load_config
validate_docker
validate_secrets "$IMAGE_TYPE"
validate_network
check_disk_space

if [[ "$CLEAN" == "true" || "$CLEAN_ALL" == "true" ]]; then
    clean_builds
fi

if [[ "$CLEAN_CACHE" == "true" || "$CLEAN_ALL" == "true" ]]; then
    clean_cache
fi

if [[ "$DRY_RUN" == "true" ]]; then
    show_disk_usage
    echo ""
    echo "Dry run complete. All validations passed."
    echo "Run without --dry-run to build."
    exit 0
fi

build "$TARGET_BOARD" "$IMAGE_TYPE"
