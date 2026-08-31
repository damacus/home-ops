package provisioning

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

type executor struct {
	stdin  io.Reader
	stdout io.Writer
	stderr io.Writer
}

func (e executor) run(
	ctx context.Context,
	dir string,
	stdin io.Reader,
	name string,
	args ...string,
) error {
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Stdin = stdin
	command.Stdout = e.stdout
	command.Stderr = e.stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("%s failed: %w", name, err)
	}
	return nil
}

func (e executor) runToStderr(
	ctx context.Context,
	dir string,
	stdin io.Reader,
	name string,
	args ...string,
) error {
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Stdin = stdin
	command.Stdout = e.stderr
	command.Stderr = e.stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("%s failed: %w", name, err)
	}
	return nil
}

// runSecret deliberately discards remote output. A peer receiving a credential
// must not be able to echo it into this command's stdout or stderr.
func (e executor) runSecret(
	ctx context.Context,
	dir string,
	stdin io.Reader,
	name string,
	args ...string,
) error {
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Stdin = stdin
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return fmt.Errorf("%s failed while transferring secret: %w", name, err)
	}
	return nil
}

func (e executor) output(
	ctx context.Context,
	dir string,
	stdin io.Reader,
	name string,
	args ...string,
) (string, error) {
	command := exec.CommandContext(ctx, name, args...)
	command.Dir = dir
	command.Stdin = stdin
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		detail := strings.TrimSpace(stderr.String())
		if captured := strings.TrimSpace(stdout.String()); captured != "" {
			if detail != "" {
				detail += "\n"
			}
			detail += captured
		}
		if detail == "" {
			detail = err.Error()
		}
		return "", fmt.Errorf("%s failed: %s", name, detail)
	}
	return strings.TrimSpace(stdout.String()), nil
}

func programAvailable(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func fileExists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}
