package provisioning

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type usageError struct {
	message string
}

func (e usageError) Error() string { return e.message }

// App owns the structured, safety-critical provisioning operations.
type App struct {
	paths           paths
	exec            executor
	deviceValidator func(string) error
	platform        func() string
}

// New returns a provisioning application rooted at the home-ops checkout.
func New(root string, stdin io.Reader, stdout, stderr io.Writer) *App {
	return &App{
		paths:           newPaths(root),
		exec:            executor{stdin: stdin, stdout: stdout, stderr: stderr},
		deviceValidator: ensureBlockDevice,
		platform:        func() string { return runtime.GOOS },
	}
}

// RunCLI executes one command and returns a process exit code.
func RunCLI(root string, args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: provisioning <command> [arguments]")
		return 2
	}
	app := New(root, stdin, stdout, stderr)
	err := app.run(context.Background(), args[0], args[1:])
	if err == nil {
		return 0
	}
	fmt.Fprintf(stderr, "error: %v\n", err)
	var invalid usageError
	if errors.As(err, &invalid) {
		return 2
	}
	return 1
}

func (a *App) run(ctx context.Context, command string, args []string) error {
	switch command {
	case "build":
		return a.runBuild(ctx, args)
	case "artifact":
		return a.runArtifact(ctx, args)
	case "armbian":
		return a.runArmbian(ctx, args)
	case "verify":
		return a.runVerify(ctx, args)
	case "flash":
		return a.runFlash(ctx, args)
	default:
		return usageError{message: fmt.Sprintf("unknown command %q", command)}
	}
}

func takeBool(args *[]string, names ...string) bool {
	for index, argument := range *args {
		for _, name := range names {
			if argument != name {
				continue
			}
			*args = append((*args)[:index], (*args)[index+1:]...)
			return true
		}
	}
	return false
}

func takeValue(args *[]string, name string) (string, bool, error) {
	for index, argument := range *args {
		if strings.HasPrefix(argument, name+"=") {
			value := strings.TrimPrefix(argument, name+"=")
			*args = append((*args)[:index], (*args)[index+1:]...)
			return value, true, nil
		}
		if argument != name {
			continue
		}
		if index+1 >= len(*args) {
			return "", false, usageError{message: name + " requires a value"}
		}
		value := (*args)[index+1]
		*args = append((*args)[:index], (*args)[index+2:]...)
		return value, true, nil
	}
	return "", false, nil
}

func requirePositionals(args []string, count int, usage string) error {
	if len(args) != count {
		return usageError{message: "usage: " + usage}
	}
	return nil
}

func writeJSON(output io.Writer, value any) error {
	encoder := json.NewEncoder(output)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}

// FindRoot locates the module root for direct CLI use.
func FindRoot(start string) (string, error) {
	if configured := os.Getenv("MISE_PROJECT_ROOT"); configured != "" {
		return filepath.Abs(configured)
	}
	current, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		module := filepath.Join(current, "go.mod")
		if data, readErr := os.ReadFile(module); readErr == nil && strings.Contains(
			string(data),
			"module github.com/damacus/home-ops",
		) {
			return current, nil
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", fmt.Errorf("could not locate home-ops root from %s", start)
		}
		current = parent
	}
}
