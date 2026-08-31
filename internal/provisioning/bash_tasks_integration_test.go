package provisioning

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestDockerDoctorReportsAllChecksOnFailure(t *testing.T) {
	fixture := newBashTaskFixture(t)
	fixture.writeExecutable(t, "docker", "#!/bin/sh\nprintf '%s\\n' '{\"Architecture\":\"amd64\",\"MemTotal\":1}'\n")
	fixture.writeExecutable(t, "df", "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev 1 1 1 99%% /\\n'\n")

	result := fixture.run(".mise/tasks/provisioning/docker/doctor")
	if result.exitCode == 0 {
		t.Fatal("docker doctor accepted a failed preflight")
	}
	for _, field := range []string{"cli", "daemon", "architecture", "memory", "host_space"} {
		if !strings.Contains(result.stdout, " "+field+":") {
			t.Fatalf("failed doctor omitted %s diagnostic: %s", field, result.stdout)
		}
	}
	if !strings.Contains(result.stderr, "Docker preflight failed") {
		t.Fatalf("failed doctor omitted summary: %s", result.stderr)
	}
}

func TestDockerDoctorSuccessReportsAllChecks(t *testing.T) {
	fixture := newBashTaskFixture(t)
	fixture.writeExecutable(t, "docker", "#!/bin/sh\nprintf '%s\\n' '{\"Architecture\":\"arm64\",\"MemTotal\":8053063680}'\n")
	fixture.writeExecutable(t, "df", "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev 1 1 52428800 1%% /\\n'\n")

	result := fixture.run(".mise/tasks/provisioning/docker/doctor")
	if result.exitCode != 0 {
		t.Fatalf("docker doctor exit code = %d, stderr = %s", result.exitCode, result.stderr)
	}
	for _, field := range []string{"cli", "daemon", "architecture", "memory", "host_space"} {
		if !strings.Contains(result.stdout, "PASS "+field+":") {
			t.Fatalf("successful doctor omitted PASS %s diagnostic: %s", field, result.stdout)
		}
	}
}

func TestDockerDoctorPreservesDaemonDiagnostic(t *testing.T) {
	fixture := newBashTaskFixture(t)
	fixture.writeExecutable(t, "docker", "#!/bin/sh\necho 'socket permission denied' >&2\nexit 1\n")
	fixture.writeExecutable(t, "df", "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev 1 1 1 99%% /\\n'\n")

	result := fixture.run(".mise/tasks/provisioning/docker/doctor")
	if result.exitCode == 0 {
		t.Fatal("docker doctor accepted an unreachable daemon")
	}
	if !strings.Contains(result.stdout, "FAIL daemon: socket permission denied") {
		t.Fatalf("daemon diagnostic was lost: %s", result.stdout)
	}
	for _, field := range []string{"cli", "daemon", "architecture", "memory", "host_space"} {
		if !strings.Contains(result.stdout, " "+field+":") {
			t.Fatalf("daemon failure omitted %s diagnostic: %s", field, result.stdout)
		}
	}
}

func TestDockerUsageReportsDirectAndRelocatedRawFiles(t *testing.T) {
	fixture := newBashTaskFixture(t)
	fixture.writeExecutable(t, "docker", "#!/bin/sh\nprintf 'docker usage\\n'\n")
	direct := filepath.Join(fixture.home, "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
	writeBashFixtureFile(t, direct, "direct")
	relocatedDir := filepath.Join(fixture.home, "relocated")
	if err := os.MkdirAll(relocatedDir, 0o755); err != nil {
		t.Fatal(err)
	}
	relocated := filepath.Join(relocatedDir, "Docker.raw")
	writeBashFixtureFile(t, relocated, "relocated")
	configuredDirect := filepath.Join(fixture.home, "configured/Docker.raw")
	writeBashFixtureFile(t, configuredDirect, "configured-direct")
	settings := filepath.Join(fixture.home, "Library/Group Containers/group.com.docker/settings-store.json")
	settingsData, err := json.Marshal(map[string]any{
		"diskImageLocation": relocatedDir,
		"nested":            map[string]string{"diskImageLocation": configuredDirect},
	})
	if err != nil {
		t.Fatal(err)
	}
	writeBashFixtureFile(t, settings, string(settingsData))

	result := fixture.run(".mise/tasks/provisioning/docker/usage")
	if result.exitCode != 0 {
		t.Fatalf("docker usage exit code = %d, stderr = %s", result.exitCode, result.stderr)
	}
	for _, path := range []string{direct, relocated, configuredDirect} {
		if !strings.Contains(result.stdout, path) {
			t.Fatalf("docker usage omitted %s: %s", path, result.stdout)
		}
	}
}

type bashTaskFixture struct {
	root string
	home string
	bin  string
}

type bashTaskResult struct {
	exitCode int
	stdout   string
	stderr   string
}

func newBashTaskFixture(t *testing.T) bashTaskFixture {
	t.Helper()
	root := moduleRoot(t)
	directory := t.TempDir()
	bin := filepath.Join(directory, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(directory, "home")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	return bashTaskFixture{root: root, home: home, bin: bin}
}

func (f bashTaskFixture) writeExecutable(t *testing.T, name, contents string) {
	t.Helper()
	writeBashFixtureFilePath(t, f.bin, name, contents, 0o755)
}

func (f bashTaskFixture) run(task string) bashTaskResult {
	command := exec.Command(task)
	command.Dir = f.root
	command.Env = append(os.Environ(),
		"HOME="+f.home,
		"PATH="+f.bin+string(os.PathListSeparator)+os.Getenv("PATH"),
		"MISE_PROJECT_ROOT="+f.root,
	)
	var stdout, stderr strings.Builder
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	result := bashTaskResult{stdout: stdout.String(), stderr: stderr.String()}
	if exit, ok := err.(*exec.ExitError); ok {
		result.exitCode = exit.ExitCode()
		return result
	}
	if err != nil {
		panic(err)
	}
	return result
}

func writeBashFixtureFile(t *testing.T, path, contents string) {
	t.Helper()
	writeBashFixtureFilePath(t, filepath.Dir(path), filepath.Base(path), contents, 0o644)
}

func writeBashFixtureFilePath(t *testing.T, directory, name, contents string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, name), []byte(contents), mode); err != nil {
		t.Fatal(err)
	}
}
