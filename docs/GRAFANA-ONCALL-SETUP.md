# Alerts and Grafana OnCall

Use this when an alert is missing, arrives at the wrong time, or reaches
Alertmanager but doesn't page. Routing and quiet hours live in Alertmanager;
Grafana Cloud OnCall handles paging after the webhook arrives.

## What is configured

Repository configuration checked on 14 November 2026: actionable receivers are
`oncall` and `oncall-critical`. Both send to the configured OnCall integration.
The current Alertmanager template has no Pushover receivers. The
[original escalation notes](ESCALATION-POLICIES-SETUP.md) describe the previous
Pushover rollout and the quiet-hours design.

The source is the
[VictoriaMetrics ExternalSecret](../kubernetes/apps/monitoring/victoria-metrics/app/externalsecret.yaml).
Its template reads the integration webhook from the `grafana-cloud-oncall`
1Password item, property `GRAFANA_ONCALL_ALERTMANAGER_URL`. Treat the URL as a
credential. Local Grafana plugin credentials are wired by the Grafana
ExternalSecrets; keep them aligned with the same Cloud stack.

## Follow a missing alert

1. Confirm the alert is firing in the rule source and inspect its labels.
2. Check which Alertmanager route matches, including silences and inhibition.
3. Check whether a quiet-hours interval applies.
4. Confirm the relevant ExternalSecrets are Ready without decoding their values.
5. Check Alertmanager delivery errors, then the Cloud OnCall integration and escalation.

```console
kubectl --context ironstone -n monitoring get externalsecret
task kubernetes:grafana-alerts
```

Don't paste a webhook URL, token or rendered Secret into logs or a bug report.
Change the manifests and 1Password source rather than relying on manual
Grafana UI edits to persist.

## Quiet hours and exceptions

Warning/info alerts use weekday-evening and weekend mute intervals. The
template has no timezone override, so its interval times are UTC. Don't read
them as Europe/London wall-clock time across daylight-saving changes.

Critical alerts use separate routes that bypass those quiet hours. Watchdog
goes to the Gatus heartbeat receiver, and InfoInhibitor goes to `null`.
UniFi radio warning/info alerts also go to `null`; critical radio and OOM
alerts have their own grouping before the general critical route.

Read the current template for the exact matchers and intervals. Quiet hours,
silences, inhibition and downstream escalation can each explain a missing page.

## Verify a routing change

Run the existing render/schema checks, then use controlled synthetic warning
and critical alerts after the approved rollout. Check that a warning respects
quiet hours, a critical alert bypasses them, and resolved groups close in
OnCall. Confirm Watchdog still reaches Gatus.

Source inspection for this documentation update did not repeat live paging or
quiet-hours checks. A rendered configuration doesn't prove delivery.

## Recover

Revert the specific reviewed routing change and reconcile it. Restore a known
working integration credential through the existing secret source if it broke.
Don't use the historical Pushover-only rollback instructions against today's
receiver configuration.

References: [Alertmanager configuration](https://prometheus.io/docs/alerting/latest/configuration/)
and [time intervals](https://prometheus.io/docs/alerting/latest/configuration/#time_interval-0).
