## Why

MedTracker now emits correlated OpenTelemetry spans, but production and canary both disable trace export because the cluster has no OTLP receiver or trace backend. This blocks production acceptance of the tracing work prompted by the missed-dose investigation and [issue #1707](https://github.com/damacus/med-tracker/issues/1707).

## What Changes

- Add a Flux-managed, single-binary Grafana Tempo deployment to the `home-ops` monitoring stack.
- Store trace blocks in a dedicated RustFS bucket using a least-privilege identity and a bounded 14-day retention policy.
- Expose Tempo's OTLP HTTP receiver and query API only inside the cluster, with network policy limiting ingestion to explicitly authorized workloads.
- Provision Tempo as a Grafana data source and configure trace-to-log navigation to the existing Loki data source.
- Enable OTLP export for MedTracker canary first, prove an exact deployed revision end to end, and promote the same configuration contract to production only after the canary acceptance matrix passes.
- Add focused repository and live-cluster verification for rendering, credentials wiring, health, ingestion, querying, privacy, retention, and rollback.

Explicit non-goals:

- Adding Tempo, an OpenTelemetry Collector, or Grafana Alloy to local Compose.
- Deploying distributed Tempo, Kafka, the Tempo Operator, service graphs, span-derived metrics, or a general-purpose cluster telemetry gateway.
- Exposing OTLP ingestion or the Tempo query API outside the cluster.
- Changing MedTracker instrumentation, sampling policy, application event schemas, or domain behavior.
- Enabling trace export for other applications.
- Treating traces as an audit record or clinically reliable medication history.
- Keeping the change open for broader observability-platform improvements discovered during implementation; those require separate changes.

## Capabilities

### New Capabilities

- `cluster-trace-backend`: Provides a private, queryable, retention-bounded OTLP trace path from an explicitly enabled MedTracker workload through Tempo to Grafana.

### Modified Capabilities

None.

## Impact

- Implementation belongs in the `home-ops` repository, principally under `kubernetes/apps/monitoring/tempo/`, the RustFS bucket and secret provisioning, Grafana data-source provisioning, MedTracker canary and production HelmRelease configuration, and focused Taskfile validation.
- Adds the official monolithic Tempo Helm chart and a single low-volume trace-backend workload to the monitoring namespace.
- Adds a dedicated RustFS bucket and credentials; no health data, trace payloads, or credentials may be committed to Git.
- Changes MedTracker canary, and later production, from `OTEL_TRACES_EXPORTER=none` to OTLP/HTTP export through a cluster-internal endpoint.
- Supplies the backend required by the production verification phase of `standardize-app-tracing-and-logging`; it does not alter that application's observability contract.
