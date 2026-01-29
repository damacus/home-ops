# Escalation Policies and DND-Aware Alerting Setup

## Overview

This document describes the implementation of Do-Not-Disturb (DND) aware escalation policies for the home-ops cluster's alerting system using Alertmanager.

## Key Learnings

### 1. Current Architecture

The home-ops cluster uses:

- **Alertmanager** (via VictoriaMetrics stack) for alert routing
- **Pushover** for notifications (not Grafana Cloud OnCall)
- **ExternalSecret** to manage Alertmanager config from 1Password

**Important**: The epic `home-ops-cil` describes deploying a self-hosted Grafana OnCall, but the current setup uses Grafana Cloud OnCall (external SaaS). Escalation policies must be configured in Alertmanager, not in OnCall itself.

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

### 9. Git Workflow

This project uses:

- **Conventional Commits**: `feat:`, `fix:`, `refactor:`, `test:`
- **Signed commits**: GPG signing via `git_commit_signed` function
- **Protected main branch**: Requires GitHub checks before merge
- **Auto-merge workflow**: `gh pr create -f && gh pr merge -sd --auto`

### 10. Beads Issue Tracking

- Issues blocked by parent epic cannot be closed (use `--force` to override)
- Use `bd sync` to export beads changes to JSONL
- Update issue notes when implementation is complete but closure is blocked

## Implementation Checklist

- [x] Add mute time intervals for weekday evenings (18:00-08:00 UTC)
- [x] Add mute time intervals for weekends (Fri 18:00 - Mon 08:00 UTC)
- [x] Create severity-based routing rules
- [x] Create critical-only receiver with high priority
- [x] Update Pushover templates with severity indicators
- [x] Commit with Conventional Commits format
- [x] Create PR and set up auto-merge
- [ ] Test DND policies with synthetic alerts
- [ ] Document runbook for testing escalation policies
- [ ] Verify critical alerts bypass DND in production

## Next Steps

1. **Deploy and verify**: Monitor Alertmanager after Flux syncs the changes
2. **Test critical alerts**: Fire test alert with `severity="critical"` during DND window
3. **Test non-critical alerts**: Fire test alert with `severity="warning"` during DND window
4. **Document runbook**: Create `docs/ESCALATION-TESTING-RUNBOOK.md`
5. **Monitor**: Watch Pushover notifications and Alertmanager logs for 1 week

## Related Issues

- **home-ops-qyh**: Configure escalation policies and notification channels (COMPLETED)
- **home-ops-cil**: Grafana On-Call: Core Setup & Configuration (PARENT EPIC)
- **home-ops-uw0**: Integrate Alertmanager with On-Call (BLOCKED)

## References

- [Alertmanager Configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [Mute Time Intervals](https://prometheus.io/docs/alerting/latest/configuration/#time_interval-0)
- [Pushover API](https://pushover.net/api)
