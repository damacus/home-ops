package clusterhealth

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

const (
	maxBackupAge          = 30 * time.Hour
	staleBackupAge        = 30 * time.Minute
	reconciliationGrace   = 10 * time.Minute
	hibernationAnnotation = "cnpg.io/hibernation"
	alertmanagerURL       = "http://localhost:9093/api/v2/alerts"
)

type Checker struct {
	Runner Runner
	Now    func() time.Time
}

func NewChecker(runner Runner) *Checker {
	return &Checker{Runner: runner, Now: time.Now}
}

func kubectlJSON[T any](ctx context.Context, checker *Checker, args ...string) (T, error) {
	var value T
	commandArgs := append(append([]string{}, args...), "-o", "json")
	output := checker.Runner.Run(ctx, "kubectl", commandArgs...)
	if output.ExitCode != 0 {
		return value, fmt.Errorf("%s", outputMessage(output, fmt.Sprintf("kubectl %v failed", args)))
	}
	if err := json.Unmarshal([]byte(output.Stdout), &value); err != nil {
		return value, fmt.Errorf("decode kubectl output: %w", err)
	}
	return value, nil
}

func remoteJSON[T any](ctx context.Context, checker *Checker, url string) (T, error) {
	var value T
	output := checker.Runner.Run(
		ctx,
		"kubectl",
		"exec", "-n", "monitoring", "vmalertmanager-vm-0", "--",
		"wget", "-qO-", url,
	)
	if output.ExitCode != 0 {
		return value, fmt.Errorf("%s", outputMessage(output, "request failed: "+url))
	}
	if err := json.Unmarshal([]byte(output.Stdout), &value); err != nil {
		return value, fmt.Errorf("decode response from %s: %w", url, err)
	}
	return value, nil
}

func (c *Checker) failedResult(name string, err error) Result {
	return Result{
		Name:    name,
		Status:  StatusFail,
		Summary: name + " check failed",
		Details: []string{err.Error()},
	}
}

func (c *Checker) age(timestamp string) (time.Duration, error) {
	parsed, err := time.Parse(time.RFC3339, timestamp)
	if err != nil {
		return 0, fmt.Errorf("parse timestamp %q: %w", timestamp, err)
	}
	return c.Now().UTC().Sub(parsed), nil
}
