#!/usr/bin/env bash
# =============================================================================
# Test a built gold master image by booting it in Lima
# =============================================================================
# Converts the .img to qcow2 and boots it in a Lima VM for testing.
# The VM gets a real LAN IP via vzNAT so it can reach NFS and k3s VIP.
#
# Usage:
#   ./test-image.sh <image-path> [--keep]
#
# Example:
#   ./test-image.sh ~/Downloads/rpi5-gold-abc123-20251216.img --keep
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 <image-path> [--keep]" >&2
  echo "" >&2
  echo "Boots a built gold master image in Lima for testing." >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  --keep    Keep VM running after boot (for debugging)" >&2
}

if [ "$#" -lt 1 ]; then
  usage
  exit 1
fi

IMAGE_PATH="${1/#\~/$HOME}"
shift

KEEP="false"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep)
      KEEP="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

if [ ! -f "$IMAGE_PATH" ]; then
  echo "ERROR: Image not found: $IMAGE_PATH" >&2
  exit 1
fi

if ! command -v limactl >/dev/null 2>&1; then
  echo "ERROR: limactl not found. Install Lima (e.g. brew install lima)." >&2
  exit 1
fi

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "ERROR: qemu-img not found. Install QEMU (e.g. brew install qemu)." >&2
  exit 1
fi

VM_NAME="ironstone-test-image"
WORKDIR=$(mktemp -d)
QCOW2_IMAGE="${WORKDIR}/disk.qcow2"

cleanup() {
  if [ "$KEEP" != "true" ]; then
    echo "Cleaning up..." >&2
    limactl stop "$VM_NAME" 2>/dev/null || true
    limactl delete "$VM_NAME" 2>/dev/null || true
    rm -rf "$WORKDIR"
  else
    echo "Keeping VM and workdir: $WORKDIR" >&2
  fi
}
trap cleanup EXIT

if limactl list -q 2>/dev/null | grep -q "^${VM_NAME}$"; then
  echo "Removing existing test VM..." >&2
  limactl stop "$VM_NAME" 2>/dev/null || true
  limactl delete "$VM_NAME" 2>/dev/null || true
fi

echo "Converting image to qcow2..." >&2
qemu-img convert -f raw -O qcow2 "$IMAGE_PATH" "$QCOW2_IMAGE"

echo "Resizing qcow2 to 10G..." >&2
qemu-img resize "$QCOW2_IMAGE" 10G

LIMA_CONFIG="${WORKDIR}/lima.yaml"
cat > "$LIMA_CONFIG" << EOF
# Lima config for testing built gold master image
minimumLimaVersion: "0.14.0"

vmType: vz
rosetta:
  enabled: false

images:
  - location: "${QCOW2_IMAGE}"
    arch: "aarch64"

cpus: 4
memory: "4GiB"
disk: "10GiB"

networks:
  - vzNAT: true

mountTypesUnsupported: [9p]
mounts: []

ssh:
  forwardAgent: true

probes:
  - description: "SSH is ready"
    script: |
      #!/bin/bash
      true
    hint: "Waiting for VM to boot..."
EOF

echo "Starting Lima VM: $VM_NAME" >&2
echo "This may take a few minutes for cloud-init to complete..." >&2
limactl start --name="$VM_NAME" "$LIMA_CONFIG" --tty=false

echo "Waiting for VM to be ready..." >&2
sleep 10

echo "" >&2
echo "===============================================" >&2
echo "VM is running!" >&2
echo "===============================================" >&2
echo "" >&2
echo "SSH into the VM:" >&2
echo "  limactl shell $VM_NAME" >&2
echo "" >&2
echo "Check cloud-init status:" >&2
echo "  limactl shell $VM_NAME -- sudo cloud-init status" >&2
echo "" >&2
echo "Check k3s service:" >&2
echo "  limactl shell $VM_NAME -- sudo systemctl status k3s" >&2
echo "" >&2

if [ "$KEEP" = "true" ]; then
  echo "VM is kept running. Stop with:" >&2
  echo "  limactl stop $VM_NAME && limactl delete $VM_NAME" >&2
  echo "" >&2
  echo "Press Ctrl+C to exit (VM will keep running)." >&2

  while true; do
    sleep 60
  done
fi
