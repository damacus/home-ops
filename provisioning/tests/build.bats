#!/usr/bin/env bats

setup() {
  export PROVISIONING_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export BUILD_SCRIPT="${PROVISIONING_DIR}/build.sh"
  export TEMP_HOME
  TEMP_HOME="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEMP_HOME}"
}

@test "fails when board or type arguments are missing" {
  run env SKIP_DOCKER_VALIDATION=true SKIP_NETWORK_VALIDATION=true HOME="${TEMP_HOME}" "${BUILD_SCRIPT}" rpi5
  [ "$status" -ne 0 ]
  [[ "${output}" == *"Both board and type are required."* ]]
}

@test "dry run flasher succeeds without K3S_TOKEN" {
  run env SKIP_DOCKER_VALIDATION=true SKIP_NETWORK_VALIDATION=true HOME="${TEMP_HOME}" K3S_TOKEN="" "${BUILD_SCRIPT}" --dry-run rpi5 flasher
  [ "$status" -eq 0 ]
  [[ "${output}" == *"Dry run complete. All validations passed."* ]]
}

@test "dry run gold fails without K3S_TOKEN" {
  run env SKIP_DOCKER_VALIDATION=true SKIP_NETWORK_VALIDATION=true HOME="${TEMP_HOME}" K3S_TOKEN="" "${BUILD_SCRIPT}" --dry-run rpi5 gold
  [ "$status" -ne 0 ]
  [[ "${output}" == *"K3S_TOKEN is required for gold images."* ]]
}

@test "build works when invoked from repo root (uses provisioning docker-compose)" {
  STUB_BIN="$(mktemp -d)"
  cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "compose" ]]; then
  if [[ ! -f "docker-compose.yaml" ]]; then
    echo "compose missing"
    exit 127
  fi
  exit 0
fi
echo "unexpected docker call: $*"
exit 1
EOF
  chmod +x "${STUB_BIN}/docker"

  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  run env PATH="${STUB_BIN}:$PATH" SKIP_DOCKER_VALIDATION=true SKIP_NETWORK_VALIDATION=true HOME="${TEMP_HOME}" \
    bash -c "cd \"${REPO_ROOT}\" && ${BUILD_SCRIPT} rock5b flasher"

  [ "$status" -eq 0 ]
  [[ "${output}" != *"compose missing"* ]]
}

@test "gold master role defines pi user" {
  run grep -E "^[[:space:]]+name: pi$" "${PROVISIONING_DIR}/ansible/roles/gold-master/tasks/main.yaml"
  [ "$status" -eq 0 ]
}
