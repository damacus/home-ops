---
name: grafana-alerts
description: Monitors and reports on active Grafana and Alertmanager alerts, documenting findings in ALERTS.md and summarizing them for the user.
---

# Grafana Alerts Agent

This skill provides a workflow for auditing active alerts and maintaining an up-to-date `ALERTS.md` report.

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

### 4. Update ALERTS.md
Create or update `ALERTS.md` in the project root with a structured report of active alerts.
- Format the report with clear headings, tables, or lists.
- Include timestamps for when the alert started.

### 5. Report to Main Thread
Provide a concise summary of the active alerts to the user, highlighting any critical issues and confirming that `ALERTS.md` has been updated.