## Verified chart schema

- Checked: `2026-07-30`
- OCI source: `oci://ghcr.io/grafana-community/helm-charts/tempo`
- Chart: `tempo` `2.2.3`
- Chart digest: `sha256:2433bb1812c07c56168b0c5dea137c6035e161c2e5794c596db8dc1842e56a2b`
- Application image version: Grafana Tempo `2.10.7`

The verified monolithic values schema supports:

- `replicas: 1`
- `tempo.tag: 2.10.7`
- `tempo.server.http_listen_port: 3200`
- `tempo.receivers.otlp.protocols.http.endpoint: 0.0.0.0:4318`
- `tempo.storage.trace.backend: s3`
- `tempo.storage.trace.s3` endpoint, bucket, credentials, and insecure/path-style settings
- `tempo.retention: 336h`
- `tempo.extraArgs` and `tempo.extraEnvFrom` for secret-backed environment expansion
- `tempo.livenessProbe`, `tempo.readinessProbe`, and `tempo.resources`
- `service.type: ClusterIP`
- `serviceMonitor.enabled`

The chart service renders several protocol ports, but the deployment will configure only the OTLP/HTTP receiver and NetworkPolicy will authorize ingress only to query port `3200` and OTLP/HTTP port `4318`.
