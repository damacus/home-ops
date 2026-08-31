package provisioning

import (
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestEnsureRootSSHPolicyIsAvailableAndIdempotentInStagedOverlay(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate test source")
	}
	repoRoot := filepath.Join(filepath.Dir(sourceFile), "../..")
	rootfs := t.TempDir()
	stageOverlay(t, filepath.Join(repoRoot, "provisioning/armbian-build/userpatches/overlay"), rootfs)
	helper := filepath.Join(rootfs, "usr/local/libexec/ironstone/ensure-root-ssh-policy.sh")
	config := filepath.Join(rootfs, "etc/ssh/sshd_config")
	initial := "PermitRootLogin yes\nInclude sshd_config.d/*.conf\n"
	if err := os.MkdirAll(filepath.Dir(config), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(config, []byte(initial), 0o644); err != nil {
		t.Fatal(err)
	}

	for run := 1; run <= 2; run++ {
		command := exec.Command("bash", helper, config)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("hardening helper run %d failed: %v (%s)", run, err, output)
		}
	}

	contents, err := os.ReadFile(config)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(contents), "\n")
	if lines[0] != "PermitRootLogin no" {
		t.Fatalf("first effective root login directive = %q, want PermitRootLogin no", lines[0])
	}
	if strings.Count(string(contents), "PermitRootLogin no\n") != 1 {
		t.Fatalf("hardening helper duplicated root login policy: %q", contents)
	}
}

func stageOverlay(t *testing.T, overlay, rootfs string) {
	t.Helper()
	if err := filepath.WalkDir(overlay, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(overlay, path)
		if err != nil {
			return err
		}
		destination := filepath.Join(rootfs, relative)
		if entry.IsDir() {
			return os.MkdirAll(destination, 0o755)
		}
		if entry.Type()&os.ModeSymlink != 0 {
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			return os.Symlink(target, destination)
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
			return err
		}
		return os.WriteFile(destination, contents, info.Mode().Perm())
	}); err != nil {
		t.Fatalf("stage overlay: %v", err)
	}
}
