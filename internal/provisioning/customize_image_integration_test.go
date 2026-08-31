package provisioning

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestEnsureRootSSHPolicyIsIdempotent(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate test source")
	}
	helper := filepath.Join(filepath.Dir(sourceFile), "../../provisioning/armbian-build/userpatches/ensure-root-ssh-policy.sh")
	config := filepath.Join(t.TempDir(), "sshd_config")
	initial := "PermitRootLogin yes\nInclude sshd_config.d/*.conf\n"
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
