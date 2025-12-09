#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_SCRIPT="${ROOT_DIR}/build.sh"

TEMP_HOME="$(mktemp -d)"
cleanup() {
    rm -rf "${TEMP_HOME}"
}
trap cleanup EXIT

assert_failure() {
    if "$@"; then
        echo "Expected failure but command succeeded: $*"
        exit 1
    fi
}

assert_success() {
    if ! "$@"; then
        echo "Expected success but command failed: $*"
        exit 1
    fi
}

echo "[TEST] build.sh should fail when arguments are missing"
assert_failure "${BUILD_SCRIPT}" rpi5

echo "[TEST] build.sh dry-run flasher should succeed without K3S_TOKEN"
HOME="${TEMP_HOME}" K3S_TOKEN="" assert_success "${BUILD_SCRIPT}" --dry-run rpi5 flasher

echo "[TEST] build.sh dry-run gold should fail without K3S_TOKEN"
HOME="${TEMP_HOME}" K3S_TOKEN="" assert_failure "${BUILD_SCRIPT}" --dry-run rpi5 gold

echo "All tests passed."
