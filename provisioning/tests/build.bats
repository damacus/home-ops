#!/usr/bin/env bats

setup() {
  export PROVISIONING_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export BUILD_SCRIPT="${PROVISIONING_DIR}/build.sh"
}

teardown() {
  true
}

@test "config.env defines required build variables" {
  run bash -c "\
    set -euo pipefail; \
    f='${PROVISIONING_DIR}/config.env'; \
    grep -q '^NFS_SERVER=' \"\$f\"; \
    grep -q '^NFS_SHARE=' \"\$f\"; \
    grep -q '^K3S_VIP=' \"\$f\"; \
    grep -q '^K3S_VERSION=' \"\$f\"; \
    grep -q '^RPI5_IMAGE_URL=' \"\$f\"; \
    grep -q '^RPI5_IMAGE_SHA256=' \"\$f\"; \
    grep -q '^ROCK5B_IMAGE_URL=' \"\$f\"; \
    grep -q '^ROCK5B_IMAGE_SHA256=' \"\$f\"
  "

  [ "$status" -eq 0 ]
}

@test "cloud-init user-data is a template (no hardcoded infra values)" {
  TEMPLATE="${PROVISIONING_DIR}/cloud-init/user-data.yaml"

  run bash -c "\
    set -euo pipefail; \
    grep -q '__K3S_VIP__' \"$TEMPLATE\"; \
    grep -q '__NFS_SERVER__' \"$TEMPLATE\"; \
    grep -q '__NFS_SHARE__' \"$TEMPLATE\" \
  "

  [ "$status" -eq 0 ]
}

@test "build.sh templates cloud-init user-data using config.env values" {
  run bash -c "\
    set -euo pipefail; \
    grep -q '__K3S_VIP__' '${PROVISIONING_DIR}/cloud-init/user-data.yaml'; \
    grep -q 'sed' '${BUILD_SCRIPT}'; \
    grep -q '__K3S_VIP__' '${BUILD_SCRIPT}'; \
    grep -q '__NFS_SERVER__' '${BUILD_SCRIPT}'; \
    grep -q '__NFS_SHARE__' '${BUILD_SCRIPT}' \
  "

  [ "$status" -eq 0 ]
}

@test "build.sh installs bootstrap init.sh and init.service" {
  run bash -c "\
    set -euo pipefail; \
    grep -q '\$CLOUD_INIT_DIR/init.sh' '${BUILD_SCRIPT}'; \
    grep -q '\$CLOUD_INIT_DIR/init.service' '${BUILD_SCRIPT}'; \
    grep -q '/usr/local/bin/ironstone-init.sh' '${BUILD_SCRIPT}'; \
    grep -q '/etc/systemd/system/ironstone-init.service' '${BUILD_SCRIPT}' \
  "

  [ "$status" -eq 0 ]
}

@test "make-seed-iso.sh exists for VM cloud-init testing" {
  [ -f "${PROVISIONING_DIR}/make-seed-iso.sh" ]
}

@test "make-seed-iso.sh renders user-data and calls genisoimage" {
  STUB_BIN="$(mktemp -d)"
  WORKDIR="$(mktemp -d)"
  OUT_ISO="${WORKDIR}/seed.iso"
  GENISO_LOG="${WORKDIR}/genisoimage.log"

  cat > "${STUB_BIN}/genisoimage" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$@" > "${GENISO_LOG}"

# Create the output file expected by callers
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-output" ]; then
    shift
    out="$1"
    break
  fi
  shift
done

if [ -z "$out" ]; then
  echo "missing -output" >&2
  exit 2
fi

mkdir -p "$(dirname "$out")"
echo "fake iso" > "$out"
EOF
  chmod +x "${STUB_BIN}/genisoimage"

  run env PATH="${STUB_BIN}:$PATH" GENISO_LOG="${GENISO_LOG}" \
    "${PROVISIONING_DIR}/make-seed-iso.sh" --output "${OUT_ISO}" --workdir "${WORKDIR}" --keep-workdir

  [ "$status" -eq 0 ]
  [ -f "${OUT_ISO}" ]
  [ -f "${GENISO_LOG}" ]
  grep -q -- "-volid" "${GENISO_LOG}"
  grep -q -- "cidata" "${GENISO_LOG}"

  # Rendered user-data should not contain placeholders
  ! grep -q -- "__K3S_VIP__" "${WORKDIR}/user-data"
  ! grep -q -- "__NFS_SERVER__" "${WORKDIR}/user-data"
  ! grep -q -- "__NFS_SHARE__" "${WORKDIR}/user-data"
}
