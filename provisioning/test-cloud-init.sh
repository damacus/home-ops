#!/usr/bin/env bash
# =============================================================================
# Test Cloud-Init Configuration in Lima VM
# =============================================================================
# Boots a gold master image in Lima and validates cloud-init functionality.
# Runs InSpec tests to verify the image is properly configured.
#
# Usage:
#   ./test-cloud-init.sh <image-path> [--profile gold|running|both]
#
# Example:
#   ./test-cloud-init.sh ~/Downloads/rpi5-gold-abc123.img --profile gold
#   ./test-cloud-init.sh ~/Downloads/rpi5-gold-abc123.img --profile running
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 <image-path> [--profile gold|running|both]" >&2
  echo "" >&2
  echo "Tests a gold master image by booting it in Lima VM." >&2
  echo "" >&2
  echo "Profiles:" >&2
  echo "  gold     - Test gold image before cloud-init runs (default)" >&2
  echo "  running  - Test running system after cloud-init completes" >&2
  echo "  both     - Run both test profiles" >&2
}

if [ "$#" -lt 1 ]; then
  usage
  exit 1
fi

IMAGE_PATH="${1/#\~/$HOME}"
shift

PROFILE="gold"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      shift
      PROFILE="${1:-gold}"
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

AUDITOR=$(command -v cinc-auditor || command -v inspec || echo "")
if [ -z "$AUDITOR" ]; then
  echo "ERROR: Neither cinc-auditor nor inspec found. Install with:" >&2
  echo "  brew install cinc-auditor" >&2
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

VM_NAME="ironstone-cloud-init-test"
WORKDIR=$(mktemp -d)
QCOW2_IMAGE="${WORKDIR}/disk.qcow2"

cleanup() {
  echo "Cleaning up..." >&2
  limactl stop "$VM_NAME" 2>/dev/null || true
  limactl delete "$VM_NAME" 2>/dev/null || true
  rm -rf "$WORKDIR"
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

run_gold_tests() {
  echo "" >&2
  echo "===============================================" >&2
  echo "Running Gold Image Tests" >&2
  echo "===============================================" >&2

  # Get SSH connection details
  SSH_CONFIG=$(limactl show-ssh --format config "$VM_NAME")
  SSH_HOST=$(echo "$SSH_CONFIG" | grep "HostName" | awk '{print $2}')
  SSH_PORT=$(echo "$SSH_CONFIG" | grep "Port" | awk '{print $2}')
  SSH_USER=$(echo "$SSH_CONFIG" | grep "User" | awk '{print $2}')
  SSH_KEY=$(echo "$SSH_CONFIG" | grep "IdentityFile" | awk '{print $2}')

  "$AUDITOR" exec "${SCRIPT_DIR}/tests/inspec-gold" \
    -t "ssh://${SSH_USER}@${SSH_HOST}:${SSH_PORT}" \
    -i "$SSH_KEY" \
    --reporter cli
}

run_running_tests() {
  echo "" >&2
  echo "===============================================" >&2
  echo "Running Post-Boot System Tests" >&2
  echo "===============================================" >&2

  echo "Waiting for cloud-init to complete..." >&2
  for i in {1..60}; do
    STATUS=$(limactl shell "$VM_NAME" -- cloud-init status 2>/dev/null || echo "pending")
    if echo "$STATUS" | grep -q "done"; then
      echo "Cloud-init completed." >&2
      break
    fi
    if echo "$STATUS" | grep -q "error"; then
      echo "WARNING: Cloud-init completed with errors." >&2
      break
    fi
    echo "  Waiting for cloud-init... ($i/60)" >&2
    sleep 5
  done

  # Get SSH connection details
  SSH_CONFIG=$(limactl show-ssh --format config "$VM_NAME")
  SSH_HOST=$(echo "$SSH_CONFIG" | grep "HostName" | awk '{print $2}')
  SSH_PORT=$(echo "$SSH_CONFIG" | grep "Port" | awk '{print $2}')
  SSH_USER=$(echo "$SSH_CONFIG" | grep "User" | awk '{print $2}')
  SSH_KEY=$(echo "$SSH_CONFIG" | grep "IdentityFile" | awk '{print $2}')

  "$AUDITOR" exec "${SCRIPT_DIR}/tests/inspec-running" \
    -t "ssh://${SSH_USER}@${SSH_HOST}:${SSH_PORT}" \
    -i "$SSH_KEY" \
    --reporter cli
}

case "$PROFILE" in
  gold)
    run_gold_tests
    ;;
  running)
    run_running_tests
    ;;
  both)
    run_gold_tests
    run_running_tests
    ;;
  *)
    echo "ERROR: Unknown profile: $PROFILE" >&2
    usage
    exit 1
    ;;
esac

echo "" >&2
echo "===============================================" >&2
echo "Tests Complete!" >&2
echo "===============================================" >&2
