## Backend and Grafana demo

- Recorded at: `2026-07-30T15:26:00Z`
- `home-ops` source revision: `fee9154235ad5ece857a4599056441add8751e1f`
- Tempo chart: `2.2.3+2433bb1812c0`
- Tempo image: `docker.io/grafana/tempo@sha256:032b3acb51ed02c4b801473d54bb63e9e9f13738d215126d9843c30283794f4b`
- Tempo HelmRelease: ready
- Tempo StatefulSet: one of one replicas ready
- Tempo service: `ClusterIP`; no Tempo Ingress or HTTPRoute exists
- RustFS: the `tempo-traces` bucket, `rustfs-tempo` user, and bucket-scoped policy passed the live IAM policy check
- VictoriaMetrics: `up{job="tempo"} == 1`
- Alerts: the controlled failed-install attempts triggered `TempoContainerRestarting`; no durable-storage alert was firing
- Grafana: Tempo, Loki, and Prometheus data-source health checks all passed; the Tempo streaming health test succeeded

The first direct demo render retained Flux's `$${VAR}` source escape and caused
Tempo to reject its literal access key. The failed release was removed before it
stored any traces, then recreated from the same manifest after `flux envsubst`.
The resulting live HelmRelease and Tempo config contain `${VAR}`, and Tempo
successfully initialized its RustFS store.

The first canary configuration used the generic OTLP endpoint. Live process
signals showed that this also activated the application's metrics exporter,
which a trace-only Tempo receiver cannot accept. The canary contract was
narrowed to the supported trace-specific `/v1/traces` endpoint; metric
transport remains outside this trace-backend change.

This evidence contains only deployment revisions, health states, and safe metric
results. It contains no credential, trace payload, medication, person, household,
or raw domain identifier.
