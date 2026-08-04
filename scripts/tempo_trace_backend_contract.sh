#!/usr/bin/env bash

set -euo pipefail

repo_root="${1:?repository root is required}"
contract_scope="${2:-full}"
tempo_dir="$repo_root/kubernetes/apps/monitoring/tempo"
tempo_app="$tempo_dir/app"
grafana_release="$repo_root/kubernetes/apps/monitoring/grafana/app/helmrelease.yaml"
monitoring_kustomization="$repo_root/kubernetes/apps/monitoring/kustomization.yaml"
storage_kustomization="$repo_root/kubernetes/apps/storage/kustomization.yaml"
rustfs_dir="$repo_root/kubernetes/apps/storage/rustfs"
rustfs_iam_dir="$repo_root/kubernetes/apps/storage/rustfs-iam"
rustfs_iam_app="$rustfs_iam_dir/app"
rustfs_bucket_job="$rustfs_iam_app/job-buckets.yaml"
rustfs_bucket_cronjob="$rustfs_iam_app/cronjob-buckets.yaml"
rustfs_bootstrap_script="$rustfs_iam_app/bootstrap-script.yaml"
rustfs_external_secret="$repo_root/kubernetes/apps/storage/rustfs/app/externalsecret.yaml"
canary_release="$repo_root/kubernetes/apps/home/med-tracker-canary/app/helmrelease.yaml"
canary_external_secret="$repo_root/kubernetes/apps/home/med-tracker-canary/app/externalsecret.yaml"
canary_kustomization="$repo_root/kubernetes/apps/home/med-tracker-canary/ks.yaml"
production_release="$repo_root/kubernetes/apps/home/med-tracker/app/helmrelease.yaml"
flux_workflow="$repo_root/.github/workflows/flux.yaml"
privacy_check="$repo_root/scripts/tempo_privacy_check.sh"
privacy_fixtures="$repo_root/tests/fixtures/tempo-privacy"

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
require_file "$rustfs_iam_dir/ks.yaml"
require_file "$rustfs_iam_app/kustomization.yaml"
require_file "$rustfs_bucket_job"
require_file "$rustfs_bucket_cronjob"
require_file "$rustfs_bootstrap_script"
require_file "$privacy_check"
require_file "$privacy_fixtures/safe-trace.json"
require_file "$privacy_fixtures/safe-loki.json"
require_file "$privacy_fixtures/unsafe-trace.json"

assert_yq '.kind == "OCIRepository" and .metadata.name == "tempo" and .spec.url == "oci://ghcr.io/grafana-community/helm-charts/tempo" and .spec.ref.tag == "2.2.3"' "$tempo_app/oci-repository.yaml"
assert_yq '.kind == "HelmRelease" and .metadata.name == "tempo" and .spec.chartRef.kind == "OCIRepository" and .spec.chartRef.name == "tempo" and .spec.values.tempo.tag == "2.10.7"' "$tempo_app/helmrelease.yaml"
assert_yq '(.spec.values.tempo.receivers | length) == 1 and (.spec.values.tempo.receivers | has("otlp")) and (.spec.values.tempo.receivers.otlp.protocols | length) == 1 and .spec.values.tempo.receivers.otlp.protocols.http.endpoint == "0.0.0.0:4318" and .spec.values.tempo.server.http_listen_port == 3200 and .spec.values.tempo.retention == "336h"' "$tempo_app/helmrelease.yaml"
assert_yq '.spec.values.tempo.storage.trace.backend == "s3" and .spec.values.tempo.storage.trace.s3.bucket == "tempo-traces" and .spec.values.tempo.storage.trace.wal.path == "/var/tempo/wal"' "$tempo_app/helmrelease.yaml"
assert_yq '.spec.values.tempo.storage.trace.s3.access_key == "$${RUSTFS_TEMPO_ACCESS_KEY}" and .spec.values.tempo.storage.trace.s3.secret_key == "$${RUSTFS_TEMPO_SECRET_KEY}"' "$tempo_app/helmrelease.yaml"
assert_yq '.spec.values.persistence.enabled == true and .spec.values.persistence.enableStatefulSetAutoDeletePVC == false and .spec.values.persistence.storageClassName == "longhorn" and (.spec.values.persistence.accessModes | length) == 1 and .spec.values.persistence.accessModes[0] == "ReadWriteOnce" and .spec.values.persistence.size == "10Gi"' "$tempo_app/helmrelease.yaml"
assert_yq '.spec.values.service.type == "ClusterIP" and .spec.values.podAnnotations."reloader.stakater.com/auto" == "true" and .spec.values.serviceAccount.automountServiceAccountToken == false' "$tempo_app/helmrelease.yaml"
assert_yq '.spec.target.name == "tempo-secret" and .spec.dataFrom[0].extract.key == "rustfs-tempo"' "$tempo_app/externalsecret.yaml"
assert_yq '.resources | contains(["externalsecret.yaml", "helmrelease.yaml", "networkpolicy.yaml", "oci-repository.yaml", "prometheusrule.yaml"])' "$tempo_app/kustomization.yaml"
assert_yq '.resources | contains(["./tempo/ks.yaml"])' "$monitoring_kustomization"
assert_yq '.spec.wait == true and (([.spec.dependsOn[].name] | sort | join(",")) == "external-secrets-stores,rustfs-iam")' "$tempo_dir/ks.yaml"

assert_match 'tempo-traces' "$rustfs_bootstrap_script"
assert_yq '.spec.template.spec.containers[0].env[] | select(.name == "RUSTFS_TEMPO_ACCESS_KEY" and .valueFrom.secretKeyRef.name == "rustfs-app-credentials" and .valueFrom.secretKeyRef.key == "RUSTFS_TEMPO_ACCESS_KEY" and .valueFrom.secretKeyRef.optional == false)' "$rustfs_bucket_job"
assert_yq '.spec.template.spec.containers[0].env[] | select(.name == "RUSTFS_TEMPO_SECRET_KEY" and .valueFrom.secretKeyRef.name == "rustfs-app-credentials" and .valueFrom.secretKeyRef.key == "RUSTFS_TEMPO_SECRET_KEY" and .valueFrom.secretKeyRef.optional == false)' "$rustfs_bucket_job"
assert_yq '.spec.schedule == "* * * * *" and .spec.concurrencyPolicy == "Forbid" and .spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "RUSTFS_TEMPO_ACCESS_KEY" and .valueFrom.secretKeyRef.key == "RUSTFS_TEMPO_ACCESS_KEY")' "$rustfs_bucket_cronjob"
assert_yq '(.data."bootstrap.sh" | test("rc admin user add rustfs")) and (.data."bootstrap.sh" | test("rc admin user ls rustfs --json")) and (.data."bootstrap.sh" | test("rc admin user rm rustfs"))' "$rustfs_bootstrap_script"
assert_yq 'select(.metadata.name == "rustfs-app-credentials") | ((.spec.target.template.data | has("RUSTFS_TEMPO_ACCESS_KEY")) and (.spec.target.template.data | has("RUSTFS_TEMPO_SECRET_KEY")))' "$rustfs_external_secret"
assert_yq '.spec.wait == true and (([.spec.dependsOn[].name] | sort | join(",")) == "external-secrets-stores,rustfs")' "$rustfs_iam_dir/ks.yaml"
assert_yq '.spec.wait == true and (([.spec.dependsOn[].name] | sort | join(",")) == "external-secrets-stores")' "$rustfs_dir/ks.yaml"
assert_yq '.resources | contains(["./rustfs/ks.yaml", "./rustfs-iam/ks.yaml"])' "$storage_kustomization"
assert_yq '.resources | contains(["bootstrap-script.yaml", "cronjob-buckets.yaml", "job-buckets.yaml"])' "$rustfs_iam_app/kustomization.yaml"
assert_yq '(.resources | contains(["./job-buckets.yaml"])) | not' "$rustfs_dir/app/kustomization.yaml"

assert_yq '.kind == "CiliumNetworkPolicy" and .metadata.name == "tempo" and .spec.endpointSelector.matchLabels."app.kubernetes.io/name" == "tempo"' "$tempo_app/networkpolicy.yaml"
assert_yq '(([.spec.ingress[].fromEndpoints[].matchLabels."k8s:app.kubernetes.io/name"] | sort | join(",")) == "grafana,med-tracker-canary,tempo-diagnostics,vmagent")' "$tempo_app/networkpolicy.yaml"
assert_yq '.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:app.kubernetes.io/name" == "med-tracker-canary" and .fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "home" and (.toPorts[0].ports | length) == 1 and .toPorts[0].ports[0].port == "4318" and .toPorts[0].ports[0].protocol == "TCP" and (.toPorts[0] | has("rules") | not))' "$tempo_app/networkpolicy.yaml"
assert_yq '.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:app.kubernetes.io/name" == "vmagent" and (.toPorts[0].rules.http | length) == 1 and .toPorts[0].rules.http[0].method == "GET" and .toPorts[0].rules.http[0].path == "^/metrics$")' "$tempo_app/networkpolicy.yaml"
assert_yq '[.spec.ingress[].toPorts[] | select(has("rules")) | .rules.http[] | select(.method != "GET" or (.path | test("flush|shutdown")))] | length == 0' "$tempo_app/networkpolicy.yaml"
for manifest in "$tempo_app"/*.yaml; do
  if yq -e 'select(.kind == "Ingress" or .kind == "HTTPRoute")' "$manifest" >/dev/null 2>&1; then
    echo "Tempo must not have a public route: $manifest" >&2
    exit 1
  fi
done
assert_yq '.kind == "PrometheusRule" and .metadata.name == "tempo" and (([.spec.groups[].rules[].alert] | sort | join(",")) == "TempoContainerRestarting,TempoDurableStorageErrors,TempoMemoryPressure,TempoRejectingSpans,TempoWalStoragePressure,TempoWorkloadUnavailable")' "$tempo_app/prometheusrule.yaml"
assert_yq '.spec.groups[].rules[] | select(.alert == "TempoWorkloadUnavailable" and (.expr | test("absent")) and (.expr | test("kube_statefulset_status_replicas_ready")))' "$tempo_app/prometheusrule.yaml"
assert_yq '.spec.groups[].rules[] | select(.alert == "TempoDurableStorageErrors" and (.expr | test("tempo_ingester_failed_flushes_total")) and (.expr | test("tempo_ingester_flush_failed_retries_total")) and (.expr | test("tempodb_retention_errors_total")))' "$tempo_app/prometheusrule.yaml"
assert_yq '.spec.groups[].rules[] | select(.alert == "TempoMemoryPressure" and (.expr | test("metrics_path=\"/metrics/cadvisor\"")) and (.expr | test("max by")))' "$tempo_app/prometheusrule.yaml"

if [[ "$contract_scope" == "foundation" ]]; then
  printf 'Tempo trace backend foundation contract passed\n'
  exit 0
fi

assert_yq '.spec.values.datasources."datasources.yaml".datasources[] | select(.name == "Tempo" and .type == "tempo" and .uid == "tempo" and .url == "http://tempo.monitoring.svc.cluster.local:3200" and .isDefault == false)' "$grafana_release"
assert_yq '.spec.values.datasources."datasources.yaml".datasources[] | select(.name == "Prometheus" and .uid == "prometheus" and .isDefault == true)' "$grafana_release"
assert_yq '.spec.values.datasources."datasources.yaml".datasources[] | select(.uid == "tempo" and .jsonData.streamingEnabled.search == true and .jsonData.tracesToLogsV2.datasourceUid == "loki" and .jsonData.tracesToLogsV2.filterByTraceID == true and (.jsonData.tracesToLogsV2.tags | length) == 1 and .jsonData.tracesToLogsV2.tags[0].key == "host.name" and .jsonData.tracesToLogsV2.tags[0].value == "pod")' "$grafana_release"
assert_yq '.spec.values.datasources."datasources.yaml".datasources[] | select(.uid == "loki" and (.jsonData.derivedFields[] | select(.name == "trace.id" and (.matcherRegex | contains("\\\\")) and (.matcherRegex | contains("trace\\.id")) and (.matcherRegex | contains("[0-9a-f]{32}")) and .datasourceUid == "tempo" and .url == "$$$${__value.raw}")))' "$grafana_release"

assert_yq '.spec.target.template.data.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT == "http://tempo.monitoring.svc.cluster.local:4318/v1/traces" and (.spec.target.template.data | has("OTEL_EXPORTER_OTLP_ENDPOINT") | not)' "$canary_external_secret"
assert_yq '.spec.values.controllers."med-tracker-canary".containers.app.env.OTEL_TRACES_EXPORTER == "otlp" and .spec.values.controllers."med-tracker-canary".containers.app.env.OTEL_EXPORTER_OTLP_PROTOCOL == "http/protobuf" and (.spec.values.controllers."med-tracker-canary".containers.app.env | has("OTEL_SERVICE_NAME") | not)' "$canary_release"
assert_yq 'explode(.) | .spec.values.controllers."med-tracker-canary".initContainers.migrate.image.tag == "sha-2b0c7327e1958f7c828f84951efe45105abadc26" and .spec.values.controllers."med-tracker-canary".containers.app.image.tag == "sha-2b0c7327e1958f7c828f84951efe45105abadc26" and .spec.values.controllers."med-tracker-canary-worker".initContainers.migrate.image.tag == "sha-2b0c7327e1958f7c828f84951efe45105abadc26" and .spec.values.controllers."med-tracker-canary-worker".containers.worker.image.tag == "sha-2b0c7327e1958f7c828f84951efe45105abadc26" and .spec.values.controllers.reset.containers.app.image.tag == "sha-2b0c7327e1958f7c828f84951efe45105abadc26"' "$canary_release"
assert_yq '.spec.values.controllers."med-tracker".containers.app.env.OTEL_TRACES_EXPORTER == "none" and (.spec.values.controllers."med-tracker".containers.app.env | has("OTEL_EXPORTER_OTLP_ENDPOINT") | not)' "$production_release"
assert_yq '.spec.wait == true and (([.spec.dependsOn[].name] | sort | join(",")) == "med-tracker-canary-db,tempo")' "$canary_kustomization"
assert_match 'task k8s:tempo-trace-backend-contract' "$flux_workflow"
"$privacy_check" "$privacy_fixtures/safe-trace.json" "$privacy_fixtures/safe-loki.json" >/dev/null
if "$privacy_check" "$privacy_fixtures/unsafe-trace.json" "$privacy_fixtures/safe-loki.json" >/dev/null 2>&1; then
  echo "Tempo privacy check accepted prohibited synthetic values" >&2
  exit 1
fi

printf 'Tempo trace backend contract passed\n'
