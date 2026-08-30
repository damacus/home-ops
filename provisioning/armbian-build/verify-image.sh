#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
exec python3 "${repository_root}/provisioning/provision.py" verify "$@"
