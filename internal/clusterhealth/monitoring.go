package clusterhealth

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strconv"
)

const alertQuery = `ALERTS{alertstate="firing",alertname!~"Watchdog|InfoInhibitor"}`

var ignoredAlerts = map[string]struct{}{
	"Watchdog":      {},
	"InfoInhibitor": {},
}

func (c *Checker) GrafanaAlerts(ctx context.Context) Result {
	queryURL := "http://vmsingle-vm.monitoring.svc.cluster.local:8428/api/v1/query?query=" +
		url.QueryEscape(alertQuery)
	payload, err := remoteJSON[prometheusResponse](ctx, c, queryURL)
	if err != nil {
		return c.failedResult("grafana-alerts", err)
	}
	details := []string{}
	for _, alert := range payload.Data.Result {
		metric := alert.Metric
		details = append(
			details,
			fmt.Sprintf(
				"%s: %s/%s",
				valueOr(metric, "alertname", "unknown"),
				valueOr(metric, "namespace", "-"),
				alertResource(metric),
			),
		)
	}
	return NewResult(
		"grafana-alerts",
		len(details) > 0,
		"no firing actionable alerts",
		fmt.Sprintf("%d firing actionable alerts", len(details)),
		details,
	)
}

func (c *Checker) Alertmanager(ctx context.Context) Result {
	alerts, err := remoteJSON[[]alertmanagerAlert](ctx, c, alertmanagerURL)
	if err != nil {
		return c.failedResult("alertmanager", err)
	}
	details := []string{}
	for _, alert := range alerts {
		if alert.Status.State != "active" {
			continue
		}
		if _, ignored := ignoredAlerts[alert.Labels["alertname"]]; ignored {
			continue
		}
		details = append(
			details,
			fmt.Sprintf(
				"%s: %s/%s",
				valueOr(alert.Labels, "alertname", "unknown"),
				valueOr(alert.Labels, "namespace", "-"),
				alertResource(alert.Labels),
			),
		)
	}
	return NewResult(
		"alertmanager",
		len(details) > 0,
		"no active actionable Alertmanager alerts",
		fmt.Sprintf("%d active actionable Alertmanager alerts", len(details)),
		details,
	)
}

func alertResource(labels map[string]string) string {
	for _, key := range []string{"deployment", "statefulset", "daemonset", "job_name", "pod", "service"} {
		if labels[key] != "" {
			return labels[key]
		}
	}
	return "-"
}

func valueOr(values map[string]string, key, fallback string) string {
	if values[key] == "" {
		return fallback
	}
	return values[key]
}

func (c *Checker) logNoiseURL(period string) string {
	query := fmt.Sprintf(`sum(count_over_time({namespace=~".+"}[%s])) by (app)`, period)
	return "http://localhost:8080/loki/api/v1/query?query=" + url.QueryEscape(query) + "&limit=100"
}

func (c *Checker) LogNoise(ctx context.Context, period string, top int) Result {
	queryURL := c.logNoiseURL(period)
	output := c.Runner.Run(
		ctx,
		"kubectl",
		"exec", "-n", "monitoring", "deploy/loki-gateway", "--",
		"wget", "-qO-", queryURL,
	)
	if output.ExitCode != 0 {
		return Result{
			Name:    "log-noise",
			Status:  StatusFail,
			Summary: "log-noise query failed",
			Details: []string{outputMessage(output, "Loki query failed")},
		}
	}
	var payload lokiResponse
	if err := json.Unmarshal([]byte(output.Stdout), &payload); err != nil {
		return Result{
			Name:    "log-noise",
			Status:  StatusFail,
			Summary: "log-noise query returned invalid JSON",
			Details: []string{err.Error()},
		}
	}
	type row struct {
		app   string
		count float64
	}
	rows := []row{}
	for _, entry := range payload.Data.Result {
		if len(entry.Value) < 2 {
			continue
		}
		count, err := parseMetricNumber(entry.Value[1])
		if err != nil {
			return Result{
				Name:    "log-noise",
				Status:  StatusFail,
				Summary: "log-noise query returned invalid data",
				Details: []string{err.Error()},
			}
		}
		app := entry.Metric["app"]
		if app == "" {
			app = "unknown"
		}
		rows = append(rows, row{app: app, count: count})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].count > rows[j].count })
	if top < len(rows) {
		rows = rows[:top]
	}
	details := make([]string, 0, len(rows))
	for _, current := range rows {
		details = append(details, fmt.Sprintf("%s: %.0f", current.app, current.count))
	}
	return Result{
		Name:    "log-noise",
		Status:  StatusPass,
		Summary: fmt.Sprintf("top %d log producers over %s", len(rows), period),
		Details: details,
	}
}

func parseMetricNumber(value any) (float64, error) {
	switch current := value.(type) {
	case string:
		parsed, err := strconv.ParseFloat(current, 64)
		if err != nil {
			return 0, fmt.Errorf("parse metric value %q: %w", current, err)
		}
		return parsed, nil
	case float64:
		return current, nil
	default:
		return 0, fmt.Errorf("unsupported metric value %v", value)
	}
}
