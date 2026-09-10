#!/usr/bin/env bash

set -euo pipefail

repo_root="${1:?repository root is required}"
production_secret="$repo_root/kubernetes/apps/home/med-tracker/app/externalsecret.yaml"

if ! yq -e '.spec.target.template.data.OIDC_MOBILE_CLIENT_ID == "{{ .mobile_client_id }}"' "$production_secret" >/dev/null; then
  echo "contract failed: production MedTracker must receive its public mobile OIDC client ID" >&2
  exit 1
fi

if ! yq -e '.spec.target.template.data.OIDC_MOBILE_CLIENT_ID != .spec.target.template.data.OIDC_CLIENT_ID' "$production_secret" >/dev/null; then
  echo "contract failed: the public mobile client must not reuse the confidential web client" >&2
  exit 1
fi

printf 'MedTracker production OIDC contract passed\n'
