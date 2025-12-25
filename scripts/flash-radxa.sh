#!/usr/bin/env bash
set -euo pipefail

IMAGE_URL="https://dl.armbian.com/rock-5b-plus/Bookworm_vendor_minimal"
IMAGE_NAME="Bookworm_vendor_minimal"
DOWNLOAD_DIR="/tmp/radxa_flash"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_deps() {
    local deps=("curl" "xz" "dd" "lsblk")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "$dep is required but not installed."
            exit 1
        fi
    done
}

download_image() {
    mkdir -p "$DOWNLOAD_DIR"
    local filename=$(basename "$IMAGE_URL")
    local filepath="$DOWNLOAD_DIR/$filename"

    if [ -f "$filepath" ]; then
        log_info "Image already downloaded at $filepath"
    else
        log_info "Downloading image from $IMAGE_URL..."
        curl -L -o "$filepath" "$IMAGE_URL"
    fi
    
    # Decompress if needed
    if [[ "$filepath" == *.xz ]]; then
        log_info "Decompressing image..."
        xz -d -k -f "$filepath"
        IMAGE_FILE="${filepath%.xz}"
    else
        IMAGE_FILE="$filepath"
    fi
    
    log_info "Image ready: $IMAGE_FILE"
}

select_drive() {
    log_info "Available drives:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "loop"
    
    echo ""
    read -p "Enter the target drive (e.g., sda, mmcblk0): " target_drive
    
    # Sanity check - ensure it's not the system drive (simplistic check)
    if [[ "$target_drive" == "nvme0n1" || "$target_drive" == "sda" ]]; then
         log_warn "WARNING: You selected $target_drive. This might be your system drive!"
         read -p "Are you ABSOLUTELY sure? (type 'yes' to continue): " confirm
         if [ "$confirm" != "yes" ]; then
             log_error "Aborted."
             exit 1
         fi
    fi

    TARGET_DEV="/dev/$target_drive"
    
    if [ ! -b "$TARGET_DEV" ]; then
        log_error "Device $TARGET_DEV does not exist."
        exit 1
    fi
}

flash_image() {
    log_warn "ABOUT TO FLASH $IMAGE_FILE TO $TARGET_DEV"
    log_warn "ALL DATA ON $TARGET_DEV WILL BE LOST!"
    read -p "Type 'flash' to confirm: " confirm
    
    if [ "$confirm" != "flash" ]; then
        log_error "Aborted."
        exit 1
    fi
    
    log_info "Flashing... This may take a while."
    sudo dd if="$IMAGE_FILE" of="$TARGET_DEV" bs=4M status=progress conv=fsync
    log_info "Flashing complete!"
    sync
}

main() {
    check_deps
    download_image
    select_drive
    flash_image
}

main
