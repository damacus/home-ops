#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_PATH="${1:-./kubernetes}"
API_VERSIONS="policy/v1/PodDisruptionBudget,monitoring.coreos.com/v1,monitoring.coreos.com/v1/ServiceMonitor,monitoring.coreos.com/v1/PodMonitor,monitoring.coreos.com/v1/PrometheusRule"

flux_local() {
  bash "${SCRIPT_DIR}/flux-local-container.sh" "$@"
}

if [[ -f "${TARGET_PATH}/ks.yaml" ]]; then
  kustomization_name="$(basename "${TARGET_PATH}")"
  target_absolute_path="$(realpath "${TARGET_PATH}")"

  flux_local build kustomization "${kustomization_name}" --path ./kubernetes

  while IFS= read -r helmrelease; do
    flux_local build helmrelease "${helmrelease}" \
      --path ./kubernetes \
      --api-versions "${API_VERSIONS}"
  done < <(
    while IFS= read -r -d '' helmrelease_file; do
      yq -r 'select(.kind == "HelmRelease") | .metadata.name' "${helmrelease_file}"
    done < <(find "${target_absolute_path}" -type f \( -iname 'helmrelease.yaml' -o -iname 'helmrelease.yml' \) -print0)
  )

  exit 0
fi

flux_local build all \
  --enable-helm \
  --api-versions "${API_VERSIONS}" \
  "${TARGET_PATH}"
