#!/bin/bash
# Validate gold image mounted at $1
set -euo pipefail

BASEDIR="${1:-/tmp/gold-test}"

echo "=== Gold Image Validation ==="
echo "Base directory: $BASEDIR"
echo ""

PASS=0
FAIL=0

check() {
    local name="$1"
    local result="$2"
    if [ "$result" = "true" ]; then
        echo "✓ $name"
        ((PASS++))
    else
        echo "✗ $name"
        ((FAIL++))
    fi
}

# Cloud-init
check "REQ-CLOUD-001: cloud-init package" "$([ -f "$BASEDIR/usr/bin/cloud-init" ] && echo true || echo false)"
check "REQ-CLOUD-002: NoCloud datasource" "$(grep -q NoCloud "$BASEDIR/etc/cloud/cloud.cfg.d/99-ironstone.cfg" 2>/dev/null && echo true || echo false)"
check "REQ-CLOUD-003: user-data present" "$([ -f "$BASEDIR/var/lib/cloud/seed/nocloud/user-data" ] && echo true || echo false)"
check "REQ-CLOUD-004: meta-data present" "$([ -f "$BASEDIR/var/lib/cloud/seed/nocloud/meta-data" ] && echo true || echo false)"
check "REQ-CLOUD-005: cloud-init state clean" "$([ ! -d "$BASEDIR/var/lib/cloud/instance" ] && echo true || echo false)"

# K3s
check "REQ-K3S-001: k3s binary" "$([ -x "$BASEDIR/usr/local/bin/k3s" ] && echo true || echo false)"
check "REQ-K3S-002: k3s symlinks" "$([ -L "$BASEDIR/usr/local/bin/kubectl" ] && [ -L "$BASEDIR/usr/local/bin/crictl" ] && echo true || echo false)"
check "REQ-K3S-003: k3s config" "$([ -f "$BASEDIR/etc/rancher/k3s/config.yaml" ] && echo true || echo false)"
check "REQ-K3S-004: k3s service" "$([ -f "$BASEDIR/etc/systemd/system/k3s.service" ] && echo true || echo false)"
check "REQ-K3S-005: k3s-init.sh" "$([ -x "$BASEDIR/usr/local/bin/k3s-init.sh" ] && echo true || echo false)"

# NFS
check "REQ-NFS-001: nfs-common installed" "$([ -f "$BASEDIR/sbin/mount.nfs" ] && echo true || echo false)"

# Init
check "REQ-INIT-001: hostname bootstrap via cloud-init bootcmd" "$(grep -qE '^[[:space:]]*bootcmd:' "$BASEDIR/var/lib/cloud/seed/nocloud/user-data" 2>/dev/null && grep -q '/usr/local/bin/ironstone-init.sh' "$BASEDIR/var/lib/cloud/seed/nocloud/user-data" 2>/dev/null && echo true || echo false)"
check "REQ-INIT-002: ironstone-init.sh" "$([ -x "$BASEDIR/usr/local/bin/ironstone-init.sh" ] && echo true || echo false)"

# Kernel/Sysctl
check "GOLD-KERNEL-CONFIG: k8s-modules.conf" "$([ -f "$BASEDIR/etc/modules-load.d/k8s-modules.conf" ] && echo true || echo false)"
check "GOLD-SYSCTL-CONFIG: 99-k8s.conf" "$([ -f "$BASEDIR/etc/sysctl.d/99-k8s.conf" ] && echo true || echo false)"

# SSH
check "GOLD-SSH-HARDENING: 99-harden.conf" "$([ -f "$BASEDIR/etc/ssh/sshd_config.d/99-harden.conf" ] && echo true || echo false)"
check "REQ-SSH-003: ssh host keys removed" "$(! ls "$BASEDIR/etc/ssh/ssh_host_"* 2>/dev/null | grep -q . && echo true || echo false)"

# System
check "REQ-SYSTEM-001: machine-id cleared" "$([ ! -s "$BASEDIR/etc/machine-id" ] && echo true || echo false)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
