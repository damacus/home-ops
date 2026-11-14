---
doc_type: history
description: Original quiet-hours implementation and alerting lessons.
---

# Escalation Policies and DND-Aware Alerting Setup

These are the original alerting implementation notes. The receiver examples
include the former Pushover route and must not be reused as current config.
Use the [current OnCall guide](GRAFANA-ONCALL-SETUP.md) for routing and debugging.

## Original approach

This document describes the implementation of Do-Not-Disturb (DND) aware escalation policies for the home-ops cluster's alerting system using Alertmanager.

## Key Learnings

### 1. Current Architecture

The home-ops cluster uses:

- **Alertmanager** (via VictoriaMetrics stack) for alert routing
- **Grafana Cloud OnCall** as the primary destination for actionable alerts
- **Pushover** as a rollout fallback notification path
- **ExternalSecret** to manage Alertmanager config from 1Password

**Important**: The epic `home-ops-cil` describes deploying a self-hosted Grafana OnCall, but the current setup uses Grafana Cloud OnCall / IRM. Routing and DND policy stay in Alertmanager; OnCall handles paging and escalation after Alertmanager sends the webhook.

### 2. DND Implementation Strategy

Alertmanager supports **mute time intervals** at the routing level. This allows:

- Declarative configuration in YAML
- Time-based alert suppression
- Severity-based routing exceptions (critical alerts bypass DND)

### 3. Mute Time Interval Syntax

Alertmanager uses Prometheus time interval syntax:

```yaml
mute_time_intervals:
  - name: weekday-evenings
    time_intervals:
      - times:
          - start_time: "18:00"
            end_time: "23:59"
        weekdays: ["monday:friday"]
      - times:
          - start_time: "00:00"
            end_time: "08:00"
        weekdays: ["tuesday:saturday"]
```

**Key points:**

- Times are in UTC (specify timezone if needed via `location` field)
- Weekday ranges use colon notation: `"monday:friday"`
- Multiple time intervals are OR'd together
- Multiple time_intervals entries are also OR'd

### 4. Severity-Based Routing

Route critical alerts separately to bypass DND:

```yaml
routes:
  - receiver: pushover-critical
    matchers:
      - severity="critical"
  - receiver: pushover
    mute_time_intervals:
      - weekday-evenings
      - weekends
    matchers:
      - severity=~"warning|info"
```

**Critical Definition**: Alerts with `severity="critical"` label. Examples:

- `KubeNodeNotReady`
- `PersistentVolumeError`
- `EtcdInsufficientMembers`
- Pod down, cluster down, data loss scenarios

### 5. Pushover Priority Levels

Pushover supports priority levels for notification behavior:

- **2**: Emergency (high priority, siren sound)
- **1**: High priority
- **0**: Normal priority
- **-1**: Low priority (no sound)

Use priority 2 for critical alerts with siren sound to ensure immediate attention.

### 6. Configuration Location

Alertmanager config is stored in:

- **File**: `kubernetes/apps/monitoring/victoria-metrics/app/externalsecret.yaml`
- **Secret**: `alertmanager-secret` (created from ExternalSecret)
- **Source**: 1Password key `alertmanager`

The ExternalSecret uses template engine v2 to render the config with secrets from 1Password.

### 7. Testing DND Policies

To verify DND policies work:

1. Create a test alert with `severity="warning"`
2. Fire it during DND window (e.g., Friday 20:00 UTC)
3. Verify notification is suppressed (check Alertmanager UI)
4. Create same alert with `severity="critical"`
5. Verify notification is sent despite DND window

### 8. Notification Templates

Use template variables in Pushover messages:

- `{{ .Status }}` - "firing" or "resolved"
- `{{ .Alerts.Firing | len }}` - count of firing alerts
- `{{ .CommonLabels.alertname }}` - alert name
- `{{ .Annotations.description }}` - alert description
- `{{ .Labels.SortedPairs }}` - all labels

Escape template delimiters in YAML:

- `{{ "{{" }}` for opening `{{`
- `{{ "}}" }}` for closing `}}`

## References

- [Alertmanager Configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [Mute Time Intervals](https://prometheus.io/docs/alerting/latest/configuration/#time_interval-0)
- [Pushover API](https://pushover.net/api)
