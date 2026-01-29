---
description: Configure DND-aware escalation policies in Alertmanager
---

# Configure Escalation Policies Workflow

This workflow implements Do-Not-Disturb (DND) aware escalation policies in Alertmanager for the home-ops cluster.

## Prerequisites

- Access to 1Password with `alertmanager` secret
- Understanding of Alertmanager configuration syntax
- Beads issue tracking setup

## Steps

### 1. Understand Current Architecture

Review the current alerting setup:

```bash
# Check ExternalSecret configuration
cat kubernetes/apps/monitoring/victoria-metrics/app/externalsecret.yaml | grep -A 50 "alertmanager.yaml"

# Verify Alertmanager is running
kubectl get pods -n monitoring | grep alertmanager
```

**Key insight**: Alertmanager config is stored in ExternalSecret and sourced from 1Password. The current setup uses Pushover for notifications, not Grafana Cloud OnCall.

### 2. Define DND Windows

Determine your DND schedule:

- **Weekday evenings**: 18:00-08:00 UTC (Mon-Fri)
- **Weekends**: Fri 18:00 UTC - Mon 08:00 UTC
- **Critical alerts**: Always notify (bypass DND)

Document these in your issue or notes.

### 3. Create Mute Time Intervals

Add mute time intervals to the Alertmanager config:

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
  - name: weekends
    time_intervals:
      - times:
          - start_time: "18:00"
            end_time: "23:59"
        weekdays: ["friday"]
      - weekdays: ["saturday", "sunday"]
      - times:
          - start_time: "00:00"
            end_time: "08:00"
        weekdays: ["monday"]
```

**File**: `kubernetes/apps/monitoring/victoria-metrics/app/externalsecret.yaml`

### 4. Configure Severity-Based Routing

Update the route section to separate critical and non-critical alerts:

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

**Critical alerts** bypass DND. **Non-critical alerts** are muted during DND windows.

### 5. Create Critical Alert Receiver

Add a new receiver for critical alerts with high priority:

```yaml
receivers:
  - name: pushover-critical
    pushover_configs:
      - html: true
        message: |
          🚨 CRITICAL ALERT 🚨
          [alert details]
        priority: 2
        sound: siren
        title: "🔴 [CRITICAL] {{ .CommonLabels.alertname }}"
        token: "{{ .ALERTMANAGER_PUSHOVER_TOKEN }}"
        user_key: "{{ .PUSHOVER_USER_KEY }}"
```

**Priority levels**:

- 2 = Emergency (siren sound)
- 1 = High
- 0 = Normal
- -1 = Low (silent)

### 6. Update Alert Templates

Enhance Pushover message templates to include severity indicators:

```yaml
message: |-
  {{ "{{-" }} range .Alerts {{ "}}" }}
    {{ "{{" }} .Annotations.description {{ "}}" }}
    [labels and details]
  {{ "{{-" }} end {{ "}}" }}
```

**Template variables**:

- `{{ .Status }}` - "firing" or "resolved"
- `{{ .Alerts.Firing | len }}` - count of alerts
- `{{ .CommonLabels.alertname }}` - alert name
- `{{ .Annotations.description }}` - description

### 7. Validate YAML Syntax

// turbo

```bash
# Validate the ExternalSecret YAML
yamllint -d relaxed kubernetes/apps/monitoring/victoria-metrics/app/externalsecret.yaml

# Check for template syntax errors
python3 -c "import yaml; yaml.safe_load(open('kubernetes/apps/monitoring/victoria-metrics/app/externalsecret.yaml'))"
```

### 8. Commit Changes

// turbo

```bash
# Stage changes
git add kubernetes/apps/monitoring/victoria-metrics/app/externalsecret.yaml

# Commit with Conventional Commits format
git_commit_signed "feat(alerting): add DND-aware escalation policies" \
  "- Add mute time intervals for weekday evenings (18:00-08:00 UTC)" \
  "- Add mute time intervals for weekends (Fri 18:00 - Mon 08:00 UTC)" \
  "- Create pushover-critical receiver with high priority (2) and siren sound" \
  "- Critical alerts bypass DND windows" \
  "- Non-critical alerts muted during DND windows"
```

### 9. Create Pull Request

// turbo

```bash
# Create PR and set up auto-merge
gh pr create -f && gh pr merge -sd --auto
```

Monitor the PR for status checks to pass.

### 10. Verify Deployment

```bash
# Wait for Flux to sync (usually 1-5 minutes)
kubectl get helmrelease -n monitoring victoria-metrics -w

# Check Alertmanager pod logs
kubectl logs -n monitoring -l app.kubernetes.io/name=alertmanager -f

# Verify config was loaded
kubectl exec -n monitoring alertmanager-0 -- cat /etc/alertmanager/alertmanager.yaml
```

### 11. Test DND Policies

Create test alerts to verify DND behavior:

```bash
# Fire a warning alert during DND window (should be muted)
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: test-warning-alert
  namespace: monitoring
spec:
  groups:
    - name: test
      interval: 30s
      rules:
        - alert: TestWarning
          expr: vector(1)
          labels:
            severity: warning
          annotations:
            description: "Test warning alert"
EOF

# Fire a critical alert (should notify immediately)
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: test-critical-alert
  namespace: monitoring
spec:
  groups:
    - name: test
      interval: 30s
      rules:
        - alert: TestCritical
          expr: vector(1)
          labels:
            severity: critical
          annotations:
            description: "Test critical alert"
EOF

# Check Alertmanager UI
kubectl port-forward -n monitoring svc/vmalertmanager-vm 9093:9093
# Visit http://localhost:9093
```

### 12. Document Results

Update the beads issue with:

- Commit hash
- Deployment timestamp
- Test results (which alerts were muted, which were sent)
- Any issues encountered

```bash
# Update issue notes
bd update home-ops-qyh --notes "Implementation complete - commit <hash>. DND-aware escalation policies configured in Alertmanager."
```

### 13. Sync Beads

// turbo

```bash
# Export beads changes
bd sync

# Commit beads changes
git add .beads/issues.jsonl
git_commit_signed "chore: update beads tracking"
```

## Troubleshooting

### Alerts still notify during DND window

- Check mute time interval names match in routes
- Verify alert has correct severity label
- Check Alertmanager logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=alertmanager`

### Template rendering errors

- Escape `{{` as `{{ "{{" }}`
- Escape `}}` as `{{ "}}" }}`
- Use `|-` for multi-line strings in YAML

### ExternalSecret not updating

- Verify 1Password secret key exists: `alertmanager`
- Check ExternalSecret status: `kubectl describe externalsecret alertmanager -n monitoring`
- Force refresh: `kubectl patch externalsecret alertmanager -n monitoring --type merge -p '{"spec":{"refreshInterval":"1m"}}'`

## References

- [Alertmanager Configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [Mute Time Intervals](https://prometheus.io/docs/alerting/latest/configuration/#time_interval-0)
- [Pushover API](https://pushover.net/api)
- [ESCALATION-POLICIES-SETUP.md](../docs/ESCALATION-POLICIES-SETUP.md)
