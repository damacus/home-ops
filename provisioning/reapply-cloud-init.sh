#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 --ssh-host <host> [--ssh-port <port>] [--ssh-user <user>] [--identity-file <path>]" >&2
  echo "" >&2
  echo "Renders CloudInit seed (user-data/meta-data), pushes it to a running node, resets cloud-init, reboots, waits for completion, then runs InSpec running profile." >&2
}

SSH_HOST=""
SSH_PORT="22"
SSH_USER="pi"
IDENTITY_FILE="${HOME}/.ssh/id_ed25519"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh-host)
      shift
      SSH_HOST="${1:-}"
      ;;
    --ssh-port)
      shift
      SSH_PORT="${1:-22}"
      ;;
    --ssh-user)
      shift
      SSH_USER="${1:-pi}"
      ;;
    --identity-file)
      shift
      IDENTITY_FILE="${1:-}"
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

if [ ! -f "$IDENTITY_FILE" ]; then
  echo "ERROR: identity file not found: $IDENTITY_FILE" >&2
  exit 1
fi

AUDITOR=$(command -v cinc-auditor || command -v inspec || echo "")
if [ -z "$AUDITOR" ]; then
  echo "ERROR: Neither cinc-auditor nor inspec found. Install with: brew install cinc-auditor" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "Rendering cloud-init seed..." >&2
"${SCRIPT_DIR}/make-seed-iso.sh" --output "${WORKDIR}/seed.iso" --workdir "$WORKDIR" --keep-workdir

USER_DATA_LOCAL="${WORKDIR}/user-data"
META_DATA_LOCAL="${WORKDIR}/meta-data"

if [ ! -f "$USER_DATA_LOCAL" ] || [ ! -f "$META_DATA_LOCAL" ]; then
  echo "ERROR: expected rendered seed files missing in $WORKDIR" >&2
  exit 1
fi

SSH_BASE=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -i "$IDENTITY_FILE"
  -p "$SSH_PORT"
)

SCP_BASE=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -i "$IDENTITY_FILE"
  -P "$SSH_PORT"
)

REMOTE="${SSH_USER}@${SSH_HOST}"

echo "Waiting for SSH before pushing seed files..." >&2
for _ in $(seq 1 60); do
  if ssh "${SSH_BASE[@]}" "$REMOTE" true 2>/dev/null; then
    break
  fi
  sleep 5
done

if ! ssh "${SSH_BASE[@]}" "$REMOTE" true 2>/dev/null; then
  echo "ERROR: SSH not reachable on ${REMOTE} (port ${SSH_PORT})" >&2
  exit 1
fi

echo "Pushing seed files to ${REMOTE}..." >&2
scp "${SCP_BASE[@]}" "$USER_DATA_LOCAL" "$META_DATA_LOCAL" "$REMOTE:/tmp/"

ssh "${SSH_BASE[@]}" "$REMOTE" bash -lc "'
  set -euo pipefail
  sudo mkdir -p /var/lib/cloud/seed/nocloud
  sudo cp /tmp/user-data /var/lib/cloud/seed/nocloud/user-data
  sudo cp /tmp/meta-data /var/lib/cloud/seed/nocloud/meta-data
  sudo chown root:root /var/lib/cloud/seed/nocloud/user-data /var/lib/cloud/seed/nocloud/meta-data
  sudo chmod 0644 /var/lib/cloud/seed/nocloud/user-data /var/lib/cloud/seed/nocloud/meta-data
'"

echo "Resetting cloud-init state..." >&2
ssh "${SSH_BASE[@]}" "$REMOTE" sudo cloud-init clean --logs

echo "Rebooting node..." >&2
ssh "${SSH_BASE[@]}" "$REMOTE" sudo reboot || true

echo "Waiting for SSH to return..." >&2
for _ in $(seq 1 60); do
  if ssh "${SSH_BASE[@]}" "$REMOTE" true 2>/dev/null; then
    break
  fi
  sleep 5
done

echo "Waiting for cloud-init to complete..." >&2
CLOUD_INIT_OK=false
for _ in $(seq 1 60); do
  if ssh "${SSH_BASE[@]}" "$REMOTE" bash -lc '
    set -euo pipefail
    if cloud-init status --wait >/dev/null 2>&1; then
      cloud-init status --wait
    else
      for i in $(seq 1 60); do
        STATUS=$(cloud-init status 2>/dev/null || echo pending)
        echo "$STATUS"
        echo "$STATUS" | grep -q "done" && exit 0
        echo "$STATUS" | grep -q "error" && exit 0
        sleep 5
      done
    fi
  '; then
    CLOUD_INIT_OK=true
    break
  fi
  sleep 5
done

if [ "$CLOUD_INIT_OK" != "true" ]; then
  echo "ERROR: failed to query cloud-init status after reboot" >&2
  exit 1
fi

echo "Running InSpec running profile against ${REMOTE}..." >&2
"$AUDITOR" exec "${SCRIPT_DIR}/tests/inspec-running" \
  -t "ssh://${SSH_USER}@${SSH_HOST}:${SSH_PORT}" \
  -i "$IDENTITY_FILE" \
  --reporter cli
