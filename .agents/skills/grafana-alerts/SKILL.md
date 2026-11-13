---
name: grafana-alerts
description: Monitors and reports on active Grafana and Alertmanager alerts, summarizing findings directly for the user.
---

# Grafana Alerts Agent

This skill provides a workflow for auditing active alerts and reporting findings directly in the conversation.

## Workflow

### 1. Fetch Grafana Alerts
Use the `list_alert_rules` tool to retrieve all Grafana-managed alert rules. Filter for those in a `firing` or `pending` state.

### 2. Fetch Alertmanager Alerts
If an Alertmanager datasource is available, use `list_alert_rules` with the `datasourceUid` to fetch Prometheus/Loki managed alerts.
- Tip: Use `list_datasources(type='prometheus')` or `list_datasources(type='loki')` to find relevant UIDs if unknown.

### 3. Analyze Alert Severity and Impact
For each active alert:
- Identify the service or component affected.
- Determine the severity (critical, warning, info).
- Extract relevant labels and annotations (summary, description).

### 4. Report Findings
Provide a concise report directly to the user:
- Identify affected resources and severity.
- Include the alert start time and relevant labels or annotations.
- Highlight critical issues and suggested next actions.

Do not create a generated report in the repository.
