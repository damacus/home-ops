# Cluster health checks

Run cluster-health checks with Mise. The tasks are read-only and use the cached
`cluster-health` binary.

```bash
mise run kubernetes:health
mise run kubernetes:health -- --format ndjson --verbose
mise run kubernetes:morning-check -- --no-edge-smoke --log-noise --period 6h --top 10
```

The individual checks are `health-nodes`, `health-kube-vip`, `health-cilium`,
`health-pods`, `health-deployments`, `cnpg-health`, `cnpg-backups`,
`gitops-health`, `external-secrets-health`, `service-account-health`,
`grafana-alerts`, `edge-smoke-esphome`, and `log-noise`.

All checker tasks accept `--format text|ndjson`, `--verbose`, `--raw`,
`--notify`, and `--timeout <duration>`. `log-noise` also accepts `--period`
and `--top`. The edge checks also accept `--skip-http3`; the ESPHome canary
accepts `--esphome-websocket-path` and `--esphome-websocket-contains`.

`health` and `morning-check` run their children in order, return failure when
any child fails, and send one aggregate notification when passed `--notify`.
`morning-check` includes edge smoke by default. Use `--no-edge-smoke` to skip
it, or `--log-noise` to include diagnostic log volume.
