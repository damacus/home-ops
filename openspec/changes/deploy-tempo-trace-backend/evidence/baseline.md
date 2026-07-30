## Baseline

- Recorded at: `2026-07-30T14:39:37Z`
- `home-ops` source revision: `fee9154235ad5ece857a4599056441add8751e1f`
- Source branch: `codex/deploy-tempo-trace-backend` from fresh `origin/main`

### Repository

- No Tempo, Jaeger, Zipkin, general OpenTelemetry Collector, or application OTLP receiver is declared under the monitoring or MedTracker application trees.
- Grafana provisions only Prometheus, Alertmanager, and Loki data sources.
- MedTracker production and canary manifests do not declare an OTLP endpoint at this revision.

### Live cluster

- The monitoring namespace has no Tempo, Jaeger, Zipkin, general OpenTelemetry Collector, or OTLP service or pod.
- Grafana has exactly three data sources: Prometheus (`prometheus`, default), Loki (`loki`), and Alertmanager (`alertmanager`).
- MedTracker production runs `ghcr.io/damacus/med-tracker:0.5.17` with `OTEL_TRACES_EXPORTER=none`.
- MedTracker canary runs `ghcr.io/damacus/med-tracker:sha-8661aa8d76d86a7f37f42f9f16515bf10cf9b692` with `OTEL_TRACES_EXPORTER=none`.

This evidence records absence and immutable workload identity only. It contains no trace payload, credential, medication, person, or household data.
