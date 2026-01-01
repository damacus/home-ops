#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.env" 2>/dev/null || true

require_var() {
    local name
    name="$1"
    if [ -z "${!name:-}" ]; then
        echo "ERROR: ${name} must be set (provisioning/config.env)" >&2
        exit 1
    fi
}

usage() {
    echo "Usage: $0 --output <seed.iso> [--template <file>] [--workdir <dir>] [--keep-workdir]" >&2
}

OUTPUT=""
TEMPLATE=""
WORKDIR=""
KEEP_WORKDIR="false"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            shift
            OUTPUT="${1:-}"
            ;;
        --workdir)
            shift
            WORKDIR="${1:-}"
            ;;
        --template)
            shift
            TEMPLATE="${1:-}"
            ;;
        --keep-workdir)
            KEEP_WORKDIR="true"
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

if [ -z "$OUTPUT" ]; then
    echo "ERROR: --output is required" >&2
    usage
    exit 1
fi

require_var K3S_VIP
require_var NFS_SERVER
require_var NFS_SHARE

if [ -z "$WORKDIR" ]; then
    WORKDIR="$(mktemp -d)"
else
    mkdir -p "$WORKDIR"
fi

cleanup() {
    if [ "$KEEP_WORKDIR" != "true" ]; then
        rm -rf "$WORKDIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ -n "$TEMPLATE" ]; then
    USER_DATA_TEMPLATE="$TEMPLATE"
else
    USER_DATA_TEMPLATE="${SCRIPT_DIR}/templates/cloud-init/user-data.yaml.j2"
fi

if [ ! -f "$USER_DATA_TEMPLATE" ]; then
    echo "ERROR: Missing cloud-init template: ${USER_DATA_TEMPLATE}" >&2
    exit 1
fi

if [[ "$USER_DATA_TEMPLATE" == *.j2 ]]; then
    MAKEJINJA_BIN="$(command -v makejinja || true)"
    MAKEJINJA_CMD=()
    if [ -n "$MAKEJINJA_BIN" ]; then
        MAKEJINJA_CMD=("$MAKEJINJA_BIN")
    elif command -v uvx >/dev/null 2>&1; then
        MAKEJINJA_CMD=(uvx makejinja)
    else
        echo "ERROR: makejinja not found and uvx is not available. Install uv (recommended) or install python deps to use templating." >&2
        exit 1
    fi

    RENDER_DIR="${WORKDIR}/rendered"
    mkdir -p "$RENDER_DIR"

    "${MAKEJINJA_CMD[@]}" \
        --input "$(dirname "$(dirname "$USER_DATA_TEMPLATE")")" \
        --output "$RENDER_DIR" \
        --jinja-suffix ".j2" \
        --data-var "K3S_VIP=${K3S_VIP}" \
        --data-var "NFS_SERVER=${NFS_SERVER}" \
        --data-var "NFS_SHARE=${NFS_SHARE}" \
        --force \
        --quiet

    cp "${RENDER_DIR}/cloud-init/user-data.yaml" "${WORKDIR}/user-data"
else
    cp "$USER_DATA_TEMPLATE" "${WORKDIR}/user-data"
fi

echo "instance-id: ironstone-vm" > "${WORKDIR}/meta-data"

mkdir -p "$(dirname "$OUTPUT")"

if [ -f "$OUTPUT" ]; then
    rm -f "$OUTPUT"
fi

if command -v genisoimage >/dev/null 2>&1; then
    genisoimage \
        -output "$OUTPUT" \
        -volid cidata \
        -joliet -rock \
        "${WORKDIR}/user-data" "${WORKDIR}/meta-data"
elif command -v hdiutil >/dev/null 2>&1; then
    STAGING="${WORKDIR}/cidata"
    mkdir -p "$STAGING"
    cp "${WORKDIR}/user-data" "$STAGING/"
    cp "${WORKDIR}/meta-data" "$STAGING/"
    hdiutil makehybrid -o "$OUTPUT" -hfs -joliet -iso -default-volume-name cidata "$STAGING"
else
    echo "ERROR: Neither genisoimage nor hdiutil found. Install cdrtools or use macOS." >&2
    exit 1
fi
