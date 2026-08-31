package clusterhealth

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

type fakeRunner struct {
	responses map[string]CommandOutput
}

func (f fakeRunner) Run(_ context.Context, name string, args ...string) CommandOutput {
	key := commandKey(name, args...)
	response, ok := f.responses[key]
	if !ok {
		return CommandOutput{Stderr: "unexpected command: " + key, ExitCode: 127}
	}
	return response
}

func commandKey(name string, args ...string) string {
	return strings.Join(append([]string{name}, args...), "\x00")
}

func kubectlGetKey(resource string) string {
	return commandKey("kubectl", "get", resource, "-A", "-o", "json")
}

func lokiQueryKey(queryURL string) string {
	return commandKey(
		"kubectl",
		"exec", "-n", "monitoring", "deploy/loki-gateway", "--",
		"wget", "-qO-", queryURL,
	)
}

func jsonOutput(value any) CommandOutput {
	payload, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return CommandOutput{Stdout: string(payload)}
}

func fixedChecker(responses map[string]CommandOutput) *Checker {
	checker := NewChecker(fakeRunner{responses: responses})
	checker.Now = func() time.Time {
		return time.Date(2026, time.May, 20, 16, 3, 0, 0, time.UTC)
	}
	return checker
}

func TestWriteNDJSONEmitsOneObjectPerLine(t *testing.T) {
	results := []Result{
		{Name: "nodes", Status: StatusPass, Summary: "all nodes Ready", Details: []string{}},
		{Name: "pods", Status: StatusFail, Summary: "one pod failed", Details: []string{"home/app"}},
	}
	var output bytes.Buffer

	if err := WriteResults(&output, results, FormatNDJSON, false, time.Time{}); err != nil {
		t.Fatal(err)
	}

	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2: %q", len(lines), output.String())
	}
	for _, line := range lines {
		var result Result
		if err := json.Unmarshal([]byte(line), &result); err != nil {
			t.Fatalf("invalid NDJSON line %q: %v", line, err)
		}
	}
}

func TestTextOutputShowsHealthyDetailsOnlyWithFullEvidence(t *testing.T) {
	result := Result{Name: "nodes", Status: StatusPass, Summary: "all nodes Ready", Details: []string{"node-a"}}
	var compact bytes.Buffer
	var full bytes.Buffer

	if err := WriteResults(&compact, []Result{result}, FormatText, false, time.Time{}); err != nil {
		t.Fatal(err)
	}
	if err := WriteResults(&full, []Result{result}, FormatText, true, time.Time{}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(compact.String(), "node-a") {
		t.Fatalf("compact output contains healthy detail: %q", compact.String())
	}
	if !strings.Contains(full.String(), "node-a") {
		t.Fatalf("full output omits healthy detail: %q", full.String())
	}
}

func TestGitOpsIgnoresSuspendedAndRecentResources(t *testing.T) {
	responses := map[string]CommandOutput{
		kubectlGetKey("gitrepository"): jsonOutput(map[string]any{"items": []any{}}),
		kubectlGetKey("helmrelease"): jsonOutput(map[string]any{"items": []any{
			map[string]any{"metadata": map[string]any{"namespace": "monitoring", "name": "grafana"}},
		}}),
		kubectlGetKey("kustomization"): jsonOutput(map[string]any{"items": []any{
			map[string]any{
				"metadata": map[string]any{"namespace": "flux-system", "name": "paused"},
				"spec":     map[string]any{"suspend": true},
				"status": map[string]any{"conditions": []any{
					map[string]any{"type": "Ready", "status": "False", "reason": "HealthCheckFailed"},
				}},
			},
			map[string]any{
				"metadata": map[string]any{"namespace": "flux-system", "name": "recent"},
				"status": map[string]any{"conditions": []any{
					map[string]any{
						"type":               "Ready",
						"status":             "False",
						"reason":             "Progressing",
						"lastTransitionTime": "2026-05-20T16:00:00Z",
					},
				}},
			},
		}}),
	}

	result := fixedChecker(responses).GitOps(context.Background())

	if result.Status != StatusFail || len(result.Details) != 1 {
		t.Fatalf("unexpected result: %#v", result)
	}
	if got := result.Details[0]; got != "HelmRelease monitoring/grafana: Ready condition missing" {
		t.Fatalf("unexpected detail: %q", got)
	}
}

func TestServiceAccountsIgnoreCompletedPods(t *testing.T) {
	responses := map[string]CommandOutput{
		kubectlGetKey("pods"): jsonOutput(map[string]any{"items": []any{
			map[string]any{
				"metadata": map[string]any{"namespace": "home", "name": "app"},
				"spec":     map[string]any{"serviceAccountName": "missing"},
				"status":   map[string]any{"phase": "Running"},
			},
			map[string]any{
				"metadata": map[string]any{"namespace": "home", "name": "finished"},
				"spec":     map[string]any{"serviceAccountName": "missing"},
				"status":   map[string]any{"phase": "Succeeded"},
			},
		}}),
		kubectlGetKey("serviceaccount"): jsonOutput(map[string]any{"items": []any{}}),
	}

	result := fixedChecker(responses).ServiceAccounts(context.Background())

	if result.Status != StatusFail || result.Summary != "1 active pod has a missing ServiceAccount" {
		t.Fatalf("unexpected result: %#v", result)
	}
	if len(result.Details) != 1 || !strings.Contains(result.Details[0], "home/app") {
		t.Fatalf("unexpected details: %#v", result.Details)
	}
}

func TestPodsReportFullFailureCountWithCappedDetails(t *testing.T) {
	items := make([]any, 0, 35)
	for index := 0; index < 35; index++ {
		items = append(items, map[string]any{
			"metadata": map[string]any{"namespace": "home", "name": fmt.Sprintf("pod-%02d", index)},
			"status":   map[string]any{"phase": "Pending"},
		})
	}
	result := fixedChecker(map[string]CommandOutput{
		kubectlGetKey("pods"): jsonOutput(map[string]any{"items": items}),
	}).Pods(context.Background())
	if result.Status != StatusFail || result.Summary != "35 active pods not ready" {
		t.Fatalf("unexpected pod failure summary: %#v", result)
	}
	if len(result.Details) != 30 || !strings.Contains(result.Details[29], "pod-29") {
		t.Fatalf("pod failure details were not capped at 30: %#v", result.Details)
	}
}

func TestExternalSecretsReportSyncFailures(t *testing.T) {
	responses := map[string]CommandOutput{
		kubectlGetKey("externalsecret"): jsonOutput(map[string]any{"items": []any{
			map[string]any{
				"metadata": map[string]any{"namespace": "home", "name": "rustfs-app-credentials"},
				"status": map[string]any{"conditions": []any{
					map[string]any{
						"type":    "Ready",
						"status":  "False",
						"reason":  "SecretSyncedError",
						"message": "missing 1Password item",
					},
				}},
			},
		}}),
	}

	result := fixedChecker(responses).ExternalSecrets(context.Background())

	if result.Status != StatusFail || result.Summary != "1 ExternalSecret not Ready" {
		t.Fatalf("unexpected result: %#v", result)
	}
	if len(result.Details) != 1 || !strings.Contains(result.Details[0], "missing 1Password item") {
		t.Fatalf("unexpected details: %#v", result.Details)
	}
}

func TestCNPGBackupsSkipHibernatedClusters(t *testing.T) {
	responses := map[string]CommandOutput{
		kubectlGetKey("backups.postgresql.cnpg.io"):          jsonOutput(map[string]any{"items": []any{}}),
		kubectlGetKey("scheduledbackups.postgresql.cnpg.io"): jsonOutput(map[string]any{"items": []any{}}),
		kubectlGetKey("clusters.postgresql.cnpg.io"): jsonOutput(map[string]any{"items": []any{
			map[string]any{
				"metadata": map[string]any{
					"namespace":   "home",
					"name":        "immich",
					"annotations": map[string]any{"cnpg.io/hibernation": "on"},
				},
			},
		}}),
	}

	result := fixedChecker(responses).CNPGBackups(context.Background())

	if result.Status != StatusPass {
		t.Fatalf("unexpected result: %#v", result)
	}
	if len(result.Details) != 1 || !strings.Contains(result.Details[0], "hibernated") {
		t.Fatalf("unexpected details: %#v", result.Details)
	}
}

func TestCNPGBackupsSkipClustersWithoutSchedule(t *testing.T) {
	responses := map[string]CommandOutput{
		kubectlGetKey("backups.postgresql.cnpg.io"): jsonOutput(map[string]any{"items": []any{}}),
		kubectlGetKey("clusters.postgresql.cnpg.io"): jsonOutput(map[string]any{"items": []any{
			map[string]any{
				"metadata": map[string]any{"namespace": "home", "name": "med-tracker-canary"},
			},
		}}),
		kubectlGetKey("scheduledbackups.postgresql.cnpg.io"): jsonOutput(map[string]any{"items": []any{}}),
	}

	result := fixedChecker(responses).CNPGBackups(context.Background())

	if result.Status != StatusPass {
		t.Fatalf("unexpected result: %#v", result)
	}
	if len(result.Details) != 1 || !strings.Contains(result.Details[0], "no ScheduledBackup configured") {
		t.Fatalf("unexpected details: %#v", result.Details)
	}
}

func TestCNPGBackupsRejectStaleSuccess(t *testing.T) {
	stoppedAt := "2026-05-19T09:03:00Z"
	responses := map[string]CommandOutput{
		kubectlGetKey("backups.postgresql.cnpg.io"): jsonOutput(map[string]any{"items": []any{
			map[string]any{
				"metadata": map[string]any{"namespace": "home", "name": "app-1", "creationTimestamp": stoppedAt},
				"spec":     map[string]any{"cluster": map[string]any{"name": "app"}},
				"status":   map[string]any{"phase": "completed", "startedAt": stoppedAt, "stoppedAt": stoppedAt},
			},
		}}),
		kubectlGetKey("clusters.postgresql.cnpg.io"): jsonOutput(map[string]any{"items": []any{
			map[string]any{"metadata": map[string]any{"namespace": "home", "name": "app"}},
		}}),
		kubectlGetKey("scheduledbackups.postgresql.cnpg.io"): jsonOutput(map[string]any{"items": []any{
			map[string]any{
				"metadata": map[string]any{"namespace": "home", "name": "app"},
				"spec":     map[string]any{"cluster": map[string]any{"name": "app"}},
			},
		}}),
		commandKey("kubectl", "cnpg", "status", "-n", "home", "app"): {
			Stdout: "Working WAL archiving: OK\nWALs waiting to be archived: 0\n",
		},
	}

	result := fixedChecker(responses).CNPGBackups(context.Background())

	if result.Status != StatusFail ||
		!strings.Contains(strings.Join(result.Details, "\n"), "31.0 hours old") {
		t.Fatalf("unexpected result: %#v", result)
	}
}

func TestArchiveStatusRejectsWaitingWALs(t *testing.T) {
	responses := map[string]CommandOutput{
		commandKey("kubectl", "cnpg", "status", "-n", "home", "app"): {
			Stdout: "Working WAL archiving: OK\nWALs waiting to be archived: 2\n",
		},
	}

	result := fixedChecker(responses).ArchiveStatus(context.Background(), "home", "app")

	if result.Status != StatusFail ||
		!strings.Contains(strings.Join(result.Details, "\n"), "2 WALs waiting") {
		t.Fatalf("unexpected result: %#v", result)
	}
}

func TestAlertmanagerIgnoresBaselineAlerts(t *testing.T) {
	alerts := []any{
		map[string]any{"status": map[string]any{"state": "active"}, "labels": map[string]any{"alertname": "Watchdog"}},
		map[string]any{"status": map[string]any{"state": "active"}, "labels": map[string]any{"alertname": "InfoInhibitor"}},
	}
	responses := map[string]CommandOutput{
		commandKey(
			"kubectl",
			"exec", "-n", "monitoring", "vmalertmanager-vm-0", "--",
			"wget", "-qO-", alertmanagerURL,
		): jsonOutput(alerts),
	}

	result := fixedChecker(responses).Alertmanager(context.Background())

	if result.Status != StatusPass || len(result.Details) != 0 {
		t.Fatalf("unexpected result: %#v", result)
	}
}

func TestLogNoiseSortsAndLimitsRows(t *testing.T) {
	payload := map[string]any{"data": map[string]any{"result": []any{
		map[string]any{"metric": map[string]any{"app": "quiet"}, "value": []any{"0", "4"}},
		map[string]any{"metric": map[string]any{"app": "noisy"}, "value": []any{"0", "19"}},
	}}}
	responses := map[string]CommandOutput{}
	checker := fixedChecker(responses)
	queryURL := checker.logNoiseURL("1h")
	responses[lokiQueryKey(queryURL)] = jsonOutput(payload)

	result := checker.LogNoise(context.Background(), "1h", 1)

	if result.Status != StatusPass || fmt.Sprint(result.Details) != "[noisy: 19]" {
		t.Fatalf("unexpected result: %#v", result)
	}
}

func TestLogNoiseRejectsMalformedMetricValues(t *testing.T) {
	payload := map[string]any{"data": map[string]any{"result": []any{
		map[string]any{"metric": map[string]any{"app": "broken"}, "value": []any{"0", "not-a-number"}},
	}}}
	responses := map[string]CommandOutput{}
	checker := fixedChecker(responses)
	queryURL := checker.logNoiseURL("1h")
	responses[lokiQueryKey(queryURL)] = jsonOutput(payload)

	result := checker.LogNoise(context.Background(), "1h", 20)

	if result.Status != StatusFail || result.Summary != "log-noise query returned invalid data" {
		t.Fatalf("unexpected result: %#v", result)
	}
}

func TestReadWebSocketFrame(t *testing.T) {
	payload, err := readWebSocketFrame(strings.NewReader("\x81\x05hello"))
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != "hello" {
		t.Fatalf("got %q, want hello", payload)
	}
}
