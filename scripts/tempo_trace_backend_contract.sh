#!/usr/bin/env bash

set -euo pipefail

repo_root="${1:?repository root is required}"
tempo_app="$repo_root/kubernetes/apps/monitoring/tempo/app"
production_release="$repo_root/kubernetes/apps/home/med-tracker/app/helmrelease.yaml"
privacy_check="$repo_root/scripts/tempo_privacy_check.sh"
privacy_fixtures="$repo_root/tests/fixtures/tempo-privacy"

assert_yq() {
  local expression="$1"
  local file="$2"
  if ! yq -e "$expression" "$file" >/dev/null; then
    echo "contract failed for $file: $expression" >&2
    exit 1
  fi
}

assert_yq '.spec.values.tempo.storage.trace.backend == "s3" and .spec.values.tempo.storage.trace.wal.path != ""' "$tempo_app/helmrelease.yaml"
# shellcheck disable=SC2016 # Flux substitutes these variables at reconciliation time.
assert_yq '.spec.values.tempo.storage.trace.s3.access_key == "$${RUSTFS_TEMPO_ACCESS_KEY}" and .spec.values.tempo.storage.trace.s3.secret_key == "$${RUSTFS_TEMPO_SECRET_KEY}"' "$tempo_app/helmrelease.yaml"
assert_yq '.spec.values.persistence.enabled == true and .spec.values.persistence.enableStatefulSetAutoDeletePVC == false' "$tempo_app/helmrelease.yaml"
assert_yq '.spec.values.service.type == "ClusterIP" and .spec.values.serviceAccount.automountServiceAccountToken == false' "$tempo_app/helmrelease.yaml"

assert_yq '.kind == "CiliumNetworkPolicy" and .spec.endpointSelector.matchLabels."app.kubernetes.io/name" == "tempo"' "$tempo_app/networkpolicy.yaml"
assert_yq '(([.spec.ingress[].fromEndpoints[].matchLabels."k8s:app.kubernetes.io/name"] | sort | join(",")) == "grafana,med-tracker-canary,tempo-diagnostics,vmagent")' "$tempo_app/networkpolicy.yaml"
assert_yq '[.spec.ingress[].toPorts[] | select(has("rules")) | .rules.http[] | select(.method != "GET" or (.path | test("flush|shutdown")))] | length == 0' "$tempo_app/networkpolicy.yaml"
for manifest in "$tempo_app"/*.yaml; do
  if yq -e 'select(.kind == "Ingress" or .kind == "HTTPRoute")' "$manifest" >/dev/null 2>&1; then
    echo "Tempo must not have a public route: $manifest" >&2
    exit 1
  fi
done

assert_yq '.spec.values.controllers."med-tracker".containers.app.env.OTEL_TRACES_EXPORTER == "none" and (.spec.values.controllers."med-tracker".containers.app.env | has("OTEL_EXPORTER_OTLP_ENDPOINT") | not)' "$production_release"

"$privacy_check" "$privacy_fixtures/safe-trace.json" "$privacy_fixtures/safe-loki.json" >/dev/null
if "$privacy_check" "$privacy_fixtures/unsafe-trace.json" "$privacy_fixtures/safe-loki.json" >/dev/null 2>&1; then
  echo "Tempo privacy check accepted prohibited synthetic values" >&2
  exit 1
fi

printf 'Tempo trace backend safety contract passed\n'
