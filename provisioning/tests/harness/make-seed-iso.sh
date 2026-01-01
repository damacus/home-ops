#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROVISIONING_DIR="${ROOT_DIR}/provisioning"

WORKDIR="$(mktemp -d)"
STUB_BIN="$(mktemp -d)"
OUT_ISO="${WORKDIR}/seed.iso"
GENISO_LOG="${WORKDIR}/genisoimage.log"

cleanup() {
  rm -rf "$WORKDIR" 2>/dev/null || true
  rm -rf "$STUB_BIN" 2>/dev/null || true
}
trap cleanup EXIT

cat > "${STUB_BIN}/makejinja" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

OUT=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then
    shift
    OUT="$1"
  fi
  shift || true
done

if [ -z "$OUT" ]; then
  echo "missing --output" >&2
  exit 2
fi

mkdir -p "${OUT}/cloud-init"
cat > "${OUT}/cloud-init/user-data.yaml" <<'EOT'
#cloud-config
bootcmd:
  - [ bash, -c, "echo bootcmd" ]
EOT
EOF
chmod +x "${STUB_BIN}/makejinja"

cat > "${STUB_BIN}/genisoimage" <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "\$@" > "${GENISO_LOG}"

out=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "-output" ]; then
    shift
    out="\$1"
    break
  fi
  shift
done

if [ -z "\$out" ]; then
  echo "missing -output" >&2
  exit 2
fi

mkdir -p "\$(dirname "\$out")"
echo "fake iso" > "\$out"
EOF
chmod +x "${STUB_BIN}/genisoimage"

env \
  PATH="${STUB_BIN}:$PATH" \
  GENISO_LOG="${GENISO_LOG}" \
  "${PROVISIONING_DIR}/make-seed-iso.sh" \
    --output "${OUT_ISO}" \
    --workdir "${WORKDIR}" \
    --keep-workdir

[ -f "${OUT_ISO}" ]
[ -f "${GENISO_LOG}" ]
grep -q -- "-volid" "${GENISO_LOG}"
grep -q -- "cidata" "${GENISO_LOG}"

[ -f "${WORKDIR}/user-data" ]
[ -f "${WORKDIR}/meta-data" ]

! grep -q -- "__K3S_VIP__" "${WORKDIR}/user-data"
! grep -q -- "__NFS_SERVER__" "${WORKDIR}/user-data"
! grep -q -- "__NFS_SHARE__" "${WORKDIR}/user-data"
