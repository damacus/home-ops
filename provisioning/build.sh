#!/bin/bash
set -euo pipefail

# =============================================================================
# Ironstone Zero-Touch Provisioning Build Script
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
  -h, --help      Show this help message
  -n, --dry-run   Validate configuration without building
  -c, --clean     Remove old build artifacts before building

Environment:
  K3S_TOKEN       Required for gold images. Can be set via:
                  - Environment variable
                  - File at ~/.secrets/k3s_token
                  - File at ./secrets/k3s_token

Examples:
  ./build.sh rpi5 gold
  ./build.sh --dry-run rock5b flasher
  ./build.sh --clean rpi5 gold

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

    local secret_paths=(
        "${HOME}/.secrets/k3s_token"
        "${SCRIPT_DIR}/secrets/k3s_token"
    )

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
    echo "Builder Image:   ${PACKER_BUILDER_IMAGE:-mkaczanowski/packer-builder-arm}"
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

# Validate required arguments
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

if [[ "$CLEAN" == "true" ]]; then
    clean_builds
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "Dry run complete. All validations passed."
    echo "Run without --dry-run to build."
    exit 0
fi

build "$TARGET_BOARD" "$IMAGE_TYPE"
