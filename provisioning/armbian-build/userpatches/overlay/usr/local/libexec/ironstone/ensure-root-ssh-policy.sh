#!/usr/bin/env bash
set -euo pipefail

ensure_root_ssh_policy() {
    local sshd_config=${1:-/etc/ssh/sshd_config}

    if [ -f "$sshd_config" ] && [ "$(sed -n '1p' "$sshd_config")" != "PermitRootLogin no" ]; then
        sed -i.bak '1i\
PermitRootLogin no
' "$sshd_config"
        rm -f "$sshd_config.bak"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    ensure_root_ssh_policy "${1:-/etc/ssh/sshd_config}"
fi
