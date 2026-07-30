#!/usr/bin/env bash

set -euo pipefail

repo_root="${1:?repository root is required}"
contract_scope="${2:-full}"
tempo_dir="$repo_root/kubernetes/apps/monitoring/tempo"
tempo_app="$tempo_dir/app"
grafana_release="$repo_root/kubernetes/apps/monitoring/grafana/app/helmrelease.yaml"
monitoring_kustomization="$repo_root/kubernetes/apps/monitoring/kustomization.yaml"
rustfs_bucket_job="$repo_root/kubernetes/apps/storage/rustfs/app/job-buckets.yaml"
rustfs_external_secret="$repo_root/kubernetes/apps/storage/rustfs/app/externalsecret.yaml"
canary_release="$repo_root/kubernetes/apps/home/med-tracker-canary/app/helmrelease.yaml"
canary_external_secret="$repo_root/kubernetes/apps/home/med-tracker-canary/app/externalsecret.yaml"
production_release="$repo_root/kubernetes/apps/home/med-tracker/app/helmrelease.yaml"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "missing required file: $1" >&2
    exit 1
  fi
}

assert_yq() {
  local expression="$1"
  local file="$2"
  if ! yq -e "$expression" "$file" >/dev/null; then
    echo "contract failed for $file: $expression" >&2
    exit 1
  fi
}

assert_match() {
  local pattern="$1"
  local file="$2"
  if ! rg --quiet "$pattern" "$file"; then
    echo "contract failed for $file: missing $pattern" >&2
    exit 1
  fi
}

require_file "$tempo_dir/ks.yaml"
require_file "$tempo_app/oci-repository.yaml"
require_file "$tempo_app/helmrelease.yaml"
require_file "$tempo_app/externalsecret.yaml"
require_file "$tempo_app/networkpolicy.yaml"
require_file "$tempo_app/prometheusrule.yaml"
require_file "$tempo_app/kustomization.yaml"

assert_yq '.kind == "OCIRepository" and .metadata.name == "tempo" and .spec.url == "oci://ghcr.io/grafana-community/helm-charts/tempo" and (.spec.ref.tag | test("^v?[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$tempo_app/oci-repository.yaml"
assert_yq '.kind == "HelmRelease" and .metadata.name == "tempo" and .spec.chartRef.kind == "OCIRepository" and .spec.chartRef.name == "tempo"' "$tempo_app/helmrelease.yaml"
assert_match '4318' "$tempo_app/helmrelease.yaml"
assert_match '3200' "$tempo_app/helmrelease.yaml"
assert_match '336h' "$tempo_app/helmrelease.yaml"
assert_match 'tempo-traces' "$tempo_app/helmrelease.yaml"
assert_yq '.spec.values.tempo.storage.trace.s3.access_key == "$${RUSTFS_TEMPO_ACCESS_KEY}" and .spec.values.tempo.storage.trace.s3.secret_key == "$${RUSTFS_TEMPO_SECRET_KEY}"' "$tempo_app/helmrelease.yaml"
assert_yq '.spec.target.name == "tempo-secret" and .spec.dataFrom[0].extract.key == "rustfs-tempo"' "$tempo_app/externalsecret.yaml"
assert_yq '.resources | contains(["externalsecret.yaml", "helmrelease.yaml", "networkpolicy.yaml", "oci-repository.yaml", "prometheusrule.yaml"])' "$tempo_app/kustomization.yaml"
assert_yq '.resources | contains(["./tempo/ks.yaml"])' "$monitoring_kustomization"

assert_match 'tempo-traces' "$rustfs_bucket_job"
assert_match 'RUSTFS_TEMPO_ACCESS_KEY' "$rustfs_bucket_job"
assert_match 'RUSTFS_TEMPO_SECRET_KEY' "$rustfs_bucket_job"
assert_yq 'select(.metadata.name == "rustfs-app-credentials") | ((.spec.target.template.data | has("RUSTFS_TEMPO_ACCESS_KEY")) and (.spec.target.template.data | has("RUSTFS_TEMPO_SECRET_KEY")))' "$rustfs_external_secret"

assert_yq '.kind == "NetworkPolicy" and .metadata.name == "tempo" and .spec.podSelector.matchLabels."app.kubernetes.io/name" == "tempo" and (([.spec.ingress[].ports[].port] | sort | join(",")) == "3200,4318")' "$tempo_app/networkpolicy.yaml"
assert_yq '.spec.ingress[] | select(.ports[0].port == 4318 and .from[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "home" and .from[0].podSelector.matchLabels."app.kubernetes.io/name" == "med-tracker-canary")' "$tempo_app/networkpolicy.yaml"
assert_yq '(([.spec.ingress[] | select(.ports[0].port == 3200).from[].podSelector.matchLabels."app.kubernetes.io/name"] | sort | join(",")) == "grafana,tempo-diagnostics,vmagent")' "$tempo_app/networkpolicy.yaml"
if [[ -e "$tempo_app/httproute.yaml" || -e "$tempo_app/ingress.yaml" ]]; then
  echo "Tempo must not have a public route" >&2
  exit 1
fi
assert_yq '.kind == "PrometheusRule" and .metadata.name == "tempo" and (([.spec.groups[].rules[].alert] | sort | join(",")) == "TempoContainerRestarting,TempoDurableStorageErrors,TempoMemoryPressure,TempoRejectingSpans,TempoWorkloadUnavailable")' "$tempo_app/prometheusrule.yaml"

if [[ "$contract_scope" == "foundation" ]]; then
  printf 'Tempo trace backend foundation contract passed\n'
  exit 0
fi

assert_yq '.spec.values.datasources."datasources.yaml".datasources[] | select(.name == "Tempo" and .type == "tempo" and .uid == "tempo" and .url == "http://tempo.monitoring.svc.cluster.local:3200" and .isDefault == false)' "$grafana_release"
assert_yq '.spec.values.datasources."datasources.yaml".datasources[] | select(.name == "Prometheus" and .uid == "prometheus" and .isDefault == true)' "$grafana_release"
assert_yq '.spec.values.datasources."datasources.yaml".datasources[] | select(.uid == "tempo" and .jsonData.streamingEnabled.search == true and .jsonData.tracesToLogsV2.datasourceUid == "loki" and .jsonData.tracesToLogsV2.filterByTraceID == true and (.jsonData.tracesToLogsV2.tags[] | select(.key == "service.name" and .value == "app")))' "$grafana_release"
assert_yq '.spec.values.datasources."datasources.yaml".datasources[] | select(.uid == "loki" and (.jsonData.derivedFields[] | select(.name == "trace.id" and .datasourceUid == "tempo" and .url == "$$$${__value.raw}")))' "$grafana_release"

assert_yq '.spec.target.template.data.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT == "http://tempo.monitoring.svc.cluster.local:4318/v1/traces" and (.spec.target.template.data | has("OTEL_EXPORTER_OTLP_ENDPOINT") | not)' "$canary_external_secret"
assert_yq '.spec.values.controllers."med-tracker-canary".containers.app.env.OTEL_TRACES_EXPORTER == "otlp" and .spec.values.controllers."med-tracker-canary".containers.app.env.OTEL_EXPORTER_OTLP_PROTOCOL == "http/protobuf" and .spec.values.controllers."med-tracker-canary".containers.app.env.OTEL_SERVICE_NAME == "med-tracker-canary"' "$canary_release"
assert_yq 'explode(.) | .spec.values.controllers."med-tracker-canary".initContainers.migrate.image.tag == "sha-1c23f5184e318f2606dd0817df0f2601eada3814" and .spec.values.controllers."med-tracker-canary".containers.app.image.tag == "sha-1c23f5184e318f2606dd0817df0f2601eada3814"' "$canary_release"
assert_yq '.spec.values.controllers."med-tracker".containers.app.env.OTEL_TRACES_EXPORTER == "none" and (.spec.values.controllers."med-tracker".containers.app.env | has("OTEL_EXPORTER_OTLP_ENDPOINT") | not)' "$production_release"

printf 'Tempo trace backend contract passed\n'
