package clusterhealth

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

type CommandOutput struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

type Runner interface {
	Run(ctx context.Context, name string, args ...string) CommandOutput
}

type ExecRunner struct {
	Timeout time.Duration
}

func (r ExecRunner) Run(ctx context.Context, name string, args ...string) CommandOutput {
	timeout := r.Timeout
	if timeout <= 0 {
		timeout = 45 * time.Second
	}
	commandCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	command := exec.CommandContext(commandCtx, name, args...)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	output := CommandOutput{Stdout: stdout.String(), Stderr: stderr.String()}
	if err == nil {
		return output
	}
	if errors.Is(commandCtx.Err(), context.DeadlineExceeded) {
		output.ExitCode = 124
		commandDescription := strings.Join(append([]string{name}, args...), " ")
		output.Stderr = fmt.Sprintf("command timed out after %s: %s", timeout, commandDescription)
		return output
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		output.ExitCode = exitError.ExitCode()
		return output
	}
	output.ExitCode = 127
	if output.Stderr == "" {
		output.Stderr = err.Error()
	}
	return output
}

func outputMessage(output CommandOutput, fallback string) string {
	if message := strings.TrimSpace(output.Stderr); message != "" {
		return message
	}
	if message := strings.TrimSpace(output.Stdout); message != "" {
		return message
	}
	return fallback
}
