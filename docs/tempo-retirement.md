# Tempo retirement

Tempo was retired on 22 October 2026. The tracing backend, its scrape and alert
resources, network policy, Grafana datasource and trace links are removed from
GitOps. The dedicated per-minute RustFS Tempo IAM reconciler is removed too.
No configured trace exporter in this repository points at the retired service.
New traces are not collected by this backend.

The `monitoring/storage-tempo-0` PVC and RustFS `tempo-traces` bucket are retained.
The PVC has no owner reference and the Helm configuration disabled StatefulSet
PVC auto-deletion. Existing bucket identities and recovery credentials remain
managed by the shared RustFS bootstrap; no bucket, object or identity deletion
is part of this uninstall. Historical trace retention processing stops with Tempo.

Grafana keeps a `deleteDatasources` entry for Tempo so an existing provisioned
datasource is removed. Prometheus/VictoriaMetrics, Loki and Grafana remain installed.

To restore the old configuration, revert this change in Git and review chart,
startup health and storage compatibility before deploying. The previous chart
upgrade and automated rollback both failed; a Git revert alone is not proof of
a working recovery. Do not delete retained storage during a recovery attempt.
