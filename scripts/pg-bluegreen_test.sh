#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

export PG_BLUEGREEN_SOURCE_ONLY=true
TEST_ROOT="/private/tmp/pg-bluegreen-test-${RANDOM}"
trap 'rm -rf "${TEST_ROOT}"' EXIT
export ROOT_DIR="${TEST_ROOT}"
export STATE_DIR="state"

# shellcheck disable=SC1091
. "${REPO_ROOT}/scripts/pg-bluegreen.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected=$1 actual=$2 message=$3
  [[ "${actual}" == "${expected}" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

cnpg_slot_sync_enabled "" || fail "omitted slot synchronization should use the CNPG default enabled state"
cnpg_slot_sync_enabled "true" || fail "explicit slot synchronization enabled should pass"
if cnpg_slot_sync_enabled "false"; then
  fail "explicit slot synchronization disabled should fail"
fi

assert_eq "" "$(missing_app_secret_keys "host,username,password,dbname")" \
  "standard CNPG app secret keys should pass"
assert_eq "username" "$(missing_app_secret_keys "host,user,password,dbname")" \
  "legacy user key should not satisfy the CNPG username key requirement"

kctl_calls=()
kctl() {
  kctl_calls+=("$*")
}

APP_DEPLOYMENTS="n8n n8n-worker"
state_file="${STATE_DIR_ABS}/restore-test.json"
mkdir -p "${STATE_DIR_ABS}"
printf '{"replicas":{"n8n":0,"n8n-worker":2}}\n' >"${state_file}"

restore_app_replicas "${state_file}"

assert_eq "scale deploy n8n --replicas=0" "${kctl_calls[0]}" \
  "restore_app_replicas should preserve an intentionally paused deployment"
assert_eq "scale deploy n8n-worker --replicas=2" "${kctl_calls[1]}" \
  "restore_app_replicas should restore non-zero replica counts"
assert_eq "rollout status deploy n8n --timeout=300s" "${kctl_calls[2]}" \
  "restore_app_replicas should still wait for n8n rollout status"
assert_eq "rollout status deploy n8n-worker --timeout=300s" "${kctl_calls[3]}" \
  "restore_app_replicas should still wait for worker rollout status"

printf 'ok - pg-bluegreen unit checks passed\n'
