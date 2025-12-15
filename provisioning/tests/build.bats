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

@test "clean succeeds without board/type and does not invoke docker" {
  STUB_BIN="$(mktemp -d)"

  cat > "${STUB_BIN}/rm" <<'EOF'
#!/usr/bin/env bash
echo "rm $*" >> "${RM_LOG}"
exit 0
EOF
  chmod +x "${STUB_BIN}/rm"

  cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker should not be invoked" >&2
exit 99
EOF
  chmod +x "${STUB_BIN}/docker"

  export RM_LOG
  RM_LOG="${TEMP_HOME}/rm.log"

  run env PATH="${STUB_BIN}:$PATH" SKIP_DOCKER_VALIDATION=true SKIP_NETWORK_VALIDATION=true HOME="${TEMP_HOME}" \
    "${BUILD_SCRIPT}" --clean

  [ "$status" -eq 0 ]
  [[ "${output}" == *"Cleaning old build artifacts"* ]]
  [[ -f "${RM_LOG}" ]]
}

@test "dry run gold fails without K3S_TOKEN" {
  run env SKIP_DOCKER_VALIDATION=true SKIP_NETWORK_VALIDATION=true HOME="${TEMP_HOME}" K3S_TOKEN="" K3S_TOKEN_ALLOW_SYSTEM_PATHS=false "${BUILD_SCRIPT}" --dry-run rpi5 gold
  [ "$status" -ne 0 ]
  [[ "${output}" == *"K3S_TOKEN is required for gold images."* ]]
}

@test "dry run gold succeeds when K3S_TOKEN_FILE points to a token file" {
  TOKEN_FILE="${TEMP_HOME}/k3s_token"
  echo "token-from-file" > "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"

  run env SKIP_DOCKER_VALIDATION=true SKIP_NETWORK_VALIDATION=true HOME="${TEMP_HOME}" K3S_TOKEN="" K3S_TOKEN_FILE="${TOKEN_FILE}" \
    "${BUILD_SCRIPT}" --dry-run rpi5 gold

  [ "$status" -eq 0 ]
  [[ "${output}" == *"Dry run complete. All validations passed."* ]]
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
