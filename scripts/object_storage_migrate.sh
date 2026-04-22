#!/usr/bin/env bash

set -euo pipefail

SOURCE_REMOTE="minio"
DEST_REMOTE="rustfs"
SOURCE_PATH=""
DEST_PATH=""
MODE="copy"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage: object_storage_migrate.sh [options]

Copy or sync objects between the MinIO and RustFS S3 endpoints using rclone.
Credentials are read from the live Kubernetes secrets in the storage namespace.

Options:
  --source <minio|rustfs>       Source remote (default: minio)
  --destination <minio|rustfs>  Destination remote (default: rustfs)
  --source-path <path>          Optional bucket/prefix on the source remote
  --destination-path <path>     Optional bucket/prefix on the destination remote
  --mode <copy|sync>            rclone mode (default: copy)
  --dry-run                     Show what would change without copying objects
  --help                        Show this message
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

normalize_path() {
  local raw="${1:-}"
  raw="${raw#/}"
  printf '%s' "$raw"
}

secret_value() {
  local namespace="$1"
  local secret_name="$2"
  local secret_key="$3"

  kubectl get secret -n "$namespace" "$secret_name" -o "jsonpath={.data.${secret_key}}" | base64 --decode
}

remote_endpoint() {
  case "$1" in
    minio) printf '%s' 'https://s3.ironstone.casa' ;;
    rustfs) printf '%s' 'https://rustfs-s3.ironstone.casa' ;;
    *)
      echo "Unsupported remote: $1" >&2
      exit 1
      ;;
  esac
}

remote_access_key() {
  case "$1" in
    minio) secret_value storage minio-root-user MINIO_ROOT_USER ;;
    rustfs) secret_value storage rustfs-credentials RUSTFS_ACCESS_KEY ;;
    *)
      echo "Unsupported remote: $1" >&2
      exit 1
      ;;
  esac
}

remote_secret_key() {
  case "$1" in
    minio) secret_value storage minio-root-user MINIO_ROOT_PASSWORD ;;
    rustfs) secret_value storage rustfs-credentials RUSTFS_SECRET_KEY ;;
    *)
      echo "Unsupported remote: $1" >&2
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_REMOTE="$2"
      shift 2
      ;;
    --destination)
      DEST_REMOTE="$2"
      shift 2
      ;;
    --source-path)
      SOURCE_PATH="$2"
      shift 2
      ;;
    --destination-path)
      DEST_PATH="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$MODE" != "copy" && "$MODE" != "sync" ]]; then
  echo "Unsupported mode: $MODE" >&2
  exit 1
fi

if [[ "$SOURCE_REMOTE" == "$DEST_REMOTE" ]]; then
  echo "Source and destination remotes must differ" >&2
  exit 1
fi

require_command kubectl
require_command rclone
require_command base64

SOURCE_PATH="$(normalize_path "$SOURCE_PATH")"
DEST_PATH="$(normalize_path "$DEST_PATH")"

RCLONE_CONFIG_FILE="$(mktemp)"
trap 'rm -f "$RCLONE_CONFIG_FILE"' EXIT

cat >"$RCLONE_CONFIG_FILE" <<EOF
[$SOURCE_REMOTE]
type = s3
provider = Minio
env_auth = false
endpoint = $(remote_endpoint "$SOURCE_REMOTE")
access_key_id = $(remote_access_key "$SOURCE_REMOTE")
secret_access_key = $(remote_secret_key "$SOURCE_REMOTE")

[$DEST_REMOTE]
type = s3
provider = Minio
env_auth = false
endpoint = $(remote_endpoint "$DEST_REMOTE")
access_key_id = $(remote_access_key "$DEST_REMOTE")
secret_access_key = $(remote_secret_key "$DEST_REMOTE")
EOF

SOURCE_SPEC="${SOURCE_REMOTE}:"
DEST_SPEC="${DEST_REMOTE}:"

if [[ -n "$SOURCE_PATH" ]]; then
  SOURCE_SPEC="${SOURCE_REMOTE}:${SOURCE_PATH}"
fi

if [[ -n "$DEST_PATH" ]]; then
  DEST_SPEC="${DEST_REMOTE}:${DEST_PATH}"
fi

RCLONE_ARGS=(
  --config "$RCLONE_CONFIG_FILE"
  "$MODE"
  "$SOURCE_SPEC"
  "$DEST_SPEC"
  --fast-list
  --checkers 16
  --transfers 8
  --s3-no-check-bucket
  --progress
)

if [[ "$DRY_RUN" == "true" ]]; then
  RCLONE_ARGS+=(--dry-run)
fi

echo "Source:      $SOURCE_SPEC"
echo "Destination: $DEST_SPEC"
echo "Mode:        $MODE"
echo "Dry run:     $DRY_RUN"

rclone "${RCLONE_ARGS[@]}"
