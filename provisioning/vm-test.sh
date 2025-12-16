#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 --ssh-host <host> [--ssh-port <port>] [--ssh-user <user>] [--identity-file <path>] [--profile <profile>] [--template <vm|production>]" >&2
  echo "" >&2
  echo "Generates a NoCloud seed ISO and runs InSpec checks against a VM over SSH." >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  --ssh-host       SSH host (required)" >&2
  echo "  --ssh-port       SSH port (default: 22)" >&2
  echo "  --ssh-user       SSH user (default: pi)" >&2
  echo "  --identity-file  SSH key (default: ~/.ssh/id_ed25519)" >&2
  echo "  --profile        InSpec profile: gold, running, or vm (default: gold)" >&2
  echo "  --template       Cloud-init template: production or vm (default: production)" >&2
  echo "" >&2
  echo "Templates:" >&2
  echo "  production  - Full cloud-init with K3s, NFS token, etc. (same as hardware)" >&2
  echo "  vm          - Lightweight template for quick VM testing" >&2
}

SSH_HOST=""
SSH_PORT="22"
SSH_USER="pi"
IDENTITY_FILE="${HOME}/.ssh/id_ed25519"
PROFILE="gold"
TEMPLATE_TYPE="production"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh-host)
      shift
      SSH_HOST="${1:-}"
      ;;
    --ssh-port)
      shift
      SSH_PORT="${1:-}"
      ;;
    --ssh-user)
      shift
      SSH_USER="${1:-}"
      ;;
    --identity-file)
      shift
      IDENTITY_FILE="${1:-}"
      ;;
    --profile)
      shift
      PROFILE="${1:-gold}"
      ;;
    --template)
      shift
      TEMPLATE_TYPE="${1:-production}"
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

if [ -z "$SSH_HOST" ]; then
  echo "ERROR: --ssh-host is required" >&2
  usage
  exit 1
fi

AUDITOR=$(command -v cinc-auditor || command -v inspec || echo "")
if [ -z "$AUDITOR" ]; then
  echo "Error: Neither cinc-auditor nor inspec found. Install with:" >&2
  echo "  brew install cinc-auditor" >&2
  exit 1
fi

SEED_ISO="${SCRIPT_DIR}/.vm/seed.iso"
mkdir -p "${SCRIPT_DIR}/.vm"

case "$TEMPLATE_TYPE" in
  production)
    TEMPLATE_FILE="${SCRIPT_DIR}/cloud-init/user-data.yaml"
    echo "Using PRODUCTION cloud-init template (same as hardware)" >&2
    ;;
  vm)
    TEMPLATE_FILE="${SCRIPT_DIR}/cloud-init/user-data-vm.yaml"
    echo "Using lightweight VM cloud-init template" >&2
    ;;
  *)
    echo "ERROR: Unknown template type: $TEMPLATE_TYPE (use 'production' or 'vm')" >&2
    exit 1
    ;;
esac

"${SCRIPT_DIR}/make-seed-iso.sh" \
  --output "$SEED_ISO" \
  --template "$TEMPLATE_FILE"

echo "Seed ISO generated at: $SEED_ISO" >&2
echo "Attach it to your VM as a CD-ROM (NoCloud cidata) and boot the VM." >&2

case "$PROFILE" in
  gold)
    INSPEC_PROFILE="${SCRIPT_DIR}/tests/inspec-gold"
    ;;
  running)
    INSPEC_PROFILE="${SCRIPT_DIR}/tests/inspec-running"
    ;;
  vm)
    INSPEC_PROFILE="${SCRIPT_DIR}/tests/inspec-vm"
    ;;
  *)
    echo "ERROR: Unknown profile: $PROFILE (use 'gold', 'running', or 'vm')" >&2
    exit 1
    ;;
esac

echo "Running InSpec profile: $PROFILE" >&2
"$AUDITOR" exec "$INSPEC_PROFILE" \
  -t "ssh://${SSH_USER}@${SSH_HOST}:${SSH_PORT}" \
  -i "$IDENTITY_FILE" \
  --reporter cli
