# Grafana Cloud OnCall Setup

## Overview

Grafana Cloud OnCall is the primary destination for actionable Alertmanager alerts. Pushover remains in the same Alertmanager receivers during rollout so alerts still produce the existing mobile signal while OnCall paging is verified.

The local Grafana instance is managed through GitOps. Do not treat manual Grafana UI changes as authoritative; update the manifests and 1Password items instead.

## Required 1Password Fields

The `grafana-cloud-oncall` item must expose these fields through External Secrets:

- `credential`: Grafana OnCall plugin token. Explicitly mapped to `GRAFANA_ONCALL_TOKEN`, then rendered into `GF_PLUGIN_GRAFANA_ONCALL_APP_ONCALL_TOKEN`.
- `GRAFANA_ONCALL_ALERTMANAGER_URL`: Alertmanager integration webhook URL copied from Grafana Cloud OnCall. Explicitly mapped into the Alertmanager template. Treat this as sensitive.

The Grafana OnCall plugin API URL is declared in `kubernetes/apps/monitoring/grafana/app/externalsecret-oncall.yaml`:

```text
https://oncall-prod-eu-west-0.grafana.net/oncall
```

## Grafana Cloud Setup

1. In Grafana Cloud OnCall, create or open the `Alertmanager Prometheus` integration for this cluster.
2. Copy the integration HTTP endpoint into the `GRAFANA_ONCALL_ALERTMANAGER_URL` field in the `grafana-cloud-oncall` 1Password item.
3. Confirm the plugin token in `credential` is valid for the same Grafana Cloud OnCall stack.
4. Let External Secrets refresh, or reconcile the relevant Flux resources.

## Verification

Run the static checks before applying changes:

```bash
task kubernetes:kubeconform
task flux:local-build path=./kubernetes/apps/monitoring/grafana
task flux:local-build path=./kubernetes/apps/monitoring/victoria-metrics
```

After Flux sync:

```bash
kubectl get secret grafana-oncall-secret -n monitoring
kubectl get secret alertmanager-secret -n monitoring
task kubernetes:grafana-alerts
```

In Grafana, verify:

- `grafana-oncall-app` is installed and enabled.
- Plugin settings use `https://oncall-prod-eu-west-0.grafana.net/oncall`.
- The plugin token is present in secure JSON fields.
- Grafana-managed alert policy routes to the `Alertmanager` contact point.

In Alertmanager, verify:

- Receivers `pushover` and `pushover-critical` include an OnCall webhook.
- `Watchdog` still routes to Gatus heartbeat.
- `InfoInhibitor` still routes to `null`.
- Warning/info alerts still respect the DND mute intervals.
- Critical alerts bypass DND.

## End-to-End Test

1. Fire a synthetic warning alert.
2. Confirm it appears in Grafana Cloud OnCall and Pushover receives the rollout duplicate.
3. Resolve the warning alert and confirm the OnCall alert group autoresolves.
4. Fire a synthetic critical alert during a DND window.
5. Confirm it pages through OnCall and still produces the critical Pushover notification.
6. Resolve the critical alert and confirm the OnCall alert group autoresolves.

## Rollback

Remove the `webhook_configs` blocks from the `pushover` and `pushover-critical` receivers in `kubernetes/apps/monitoring/victoria-metrics/app/externalsecret.yaml`, then reconcile Flux. This returns routing to Pushover-only without changing Grafana dashboards or alert rules.
