#!/usr/bin/env bash
set -euo pipefail

PROVISIONING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

AUDITOR="$(command -v cinc-auditor || command -v inspec || true)"
if [ -z "$AUDITOR" ]; then
  echo "Error: Neither cinc-auditor nor inspec found. Install with:"
  echo "  brew install cinc-auditor"
  exit 1
fi

echo "Running $AUDITOR repo checks..."
"$AUDITOR" exec "$PROVISIONING_DIR/tests/inspec-repo" -t local:// --reporter cli
