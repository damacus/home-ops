package provisioning

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestVerifyRootFSIntegrationRejectsSecurityRegression(t *testing.T) {
	fixture := newVerificationFixture(t)
	binary := buildProvisioningCommand(t, fixture.root)

	code, stdout, stderr := runProvisioningCommand(t, binary, fixture.root, []string{
		"verify", "--rootfs", fixture.rootfs, "--manifest", fixture.manifest,
		"--k3s-version", "k3s version v1.36.3+k3s1 (abcdef)", "--raw",
	})
	if code != 0 {
		t.Fatalf("verify exit code = %d, stdout = %s, stderr = %s", code, stdout, stderr)
	}
	var report verificationReport
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("verify JSON: %v", err)
	}
	if report.Status != "pass" {
		t.Fatalf("verification status = %q, checks = %#v", report.Status, report.Checks)
	}

	if err := os.WriteFile(filepath.Join(fixture.rootfs, "etc/ssh/sshd_config.d/00-hardening.conf"), []byte("PasswordAuthentication yes\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, stdout, stderr = runProvisioningCommand(t, binary, fixture.root, []string{
		"verify", "--rootfs", fixture.rootfs, "--manifest", fixture.manifest,
		"--k3s-version", "k3s version v1.36.3+k3s1 (abcdef)", "--raw",
	})
	if code == 0 {
		t.Fatal("verify accepted password SSH authentication")
	}
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("security regression report JSON: %v", err)
	}
	if report.Checks["ssh_policy"].Status != "fail" {
		t.Fatalf("ssh policy did not fail: %#v", report.Checks["ssh_policy"])
	}
}

func buildProvisioningCommand(t *testing.T, destination string) string {
	t.Helper()
	repo, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(destination, "provisioning")
	command := exec.Command("go", "build", "-o", binary, "./cmd/provisioning")
	command.Dir = repo
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("build provisioning command: %v\n%s", err, output)
	}
	return binary
}

func runProvisioningCommand(t *testing.T, binary, directory string, args []string) (int, string, string) {
	t.Helper()
	command := exec.Command(binary, args...)
	command.Dir = directory
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	if err == nil {
		return 0, stdout.String(), stderr.String()
	}
	if exitError, ok := err.(*exec.ExitError); ok {
		return exitError.ExitCode(), stdout.String(), stderr.String()
	}
	t.Fatalf("run provisioning command: %v", err)
	return 0, "", ""
}

func TestFlashDryRunDoesNotInspectSuppliedPaths(t *testing.T) {
	root := t.TempDir()
	var stdout, stderr bytes.Buffer
	if code := RunCLI(root, []string{"flash", "missing.img.xz", "/not/a/device", "--dry-run"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("flash dry-run exit code = %d, stderr = %s", code, stderr.String())
	}
	var plan map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &plan); err != nil {
		t.Fatalf("flash dry-run JSON: %v", err)
	}
	if plan["device"] != "/not/a/device" || plan["remote_download"] != false {
		t.Fatalf("unexpected flash dry-run plan: %#v", plan)
	}
}

func TestFlashStreamUsesControlledWriter(t *testing.T) {
	root := t.TempDir()
	bin := t.TempDir()
	image := filepath.Join(root, "image.img.xz")
	record := filepath.Join(root, "written-image")
	arguments := filepath.Join(root, "writer-arguments")
	writeFixtureFile(t, image, "golden image\n")
	writeFixtureFile(t, filepath.Join(bin, "xz"), "#!/bin/sh\ncat \"$2\"\n")
	writeFixtureFile(t, filepath.Join(bin, "sudo"), "#!/bin/sh\ntest \"$1\" = dd\nprintf '%s\\n' \"$@\" >\"$FLASH_ARGUMENTS\"\ncat >\"$FLASH_RECORD\"\n")
	if err := os.Chmod(filepath.Join(bin, "xz"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(bin, "sudo"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FLASH_RECORD", record)
	t.Setenv("FLASH_ARGUMENTS", arguments)
	app := New(root, strings.NewReader(""), io.Discard, io.Discard)
	if err := app.streamImageToDevice(t.Context(), image, "/dev/fake-disk"); err != nil {
		t.Fatal(err)
	}
	written, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	if string(written) != "golden image\n" {
		t.Fatalf("writer received %q", written)
	}
	writerArguments, err := os.ReadFile(arguments)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(writerArguments), "of=/dev/fake-disk") || !strings.Contains(string(writerArguments), "conv=fsync") {
		t.Fatalf("unexpected writer arguments: %s", writerArguments)
	}
}

type verificationFixture struct {
	root     string
	rootfs   string
	manifest string
}

func newVerificationFixture(t *testing.T) verificationFixture {
	t.Helper()
	root := t.TempDir()
	rootfs := filepath.Join(root, "rootfs")
	writeFixtureFile(t, filepath.Join(root, "go.mod"), "module github.com/damacus/home-ops\ngo 1.26.6\n")
	writeFixtureFile(t, filepath.Join(root, "kubernetes/apps/system-upgrade/k3s/app/plan.yaml"), "version: v1.36.3+k3s1\n")
	writeFixtureFile(t, filepath.Join(rootfs, "etc/os-release"), "NAME=Ubuntu\n")
	writeFixtureFile(t, filepath.Join(rootfs, "etc/passwd"), "root:x:0:0:root:/root:/bin/bash\npi:x:1000:1000:pi:/home/pi:/bin/bash\n")
	writeFixtureFile(t, filepath.Join(rootfs, "etc/shadow"), "root:!:1:2:3:4:5:6:\npi:!:1:2:3:4:5:6:\n")
	writeFixtureFile(t, filepath.Join(rootfs, "etc/ssh/sshd_config"), "Include /etc/ssh/sshd_config.d/*.conf\n")
	writeFixtureFile(t, filepath.Join(rootfs, "etc/ssh/sshd_config.d/00-hardening.conf"), "PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n")
	writeFixtureFile(t, filepath.Join(rootfs, "home/pi/.ssh/authorized_keys"), PublicKey+"\n")
	for _, path := range []string{
		filepath.Join(rootfs, "home/pi"),
		filepath.Join(rootfs, "home/pi/.ssh"),
	} {
		if err := os.Chmod(path, map[string]os.FileMode{
			filepath.Join(rootfs, "home/pi"):      0o750,
			filepath.Join(rootfs, "home/pi/.ssh"): 0o700,
		}[path]); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(filepath.Join(rootfs, "home/pi/.ssh/authorized_keys"), 0o600); err != nil {
		t.Fatal(err)
	}
	writeFixtureFile(t, filepath.Join(rootfs, "etc/apt/apt.conf.d/20auto-upgrades"), "APT::Periodic::Unattended-Upgrade \"1\";\n")
	writeFixtureFile(t, filepath.Join(rootfs, "etc/apt/apt.conf.d/50unattended-upgrades"), "Ubuntu:noble\nUbuntu:noble-updates\nUbuntu:noble-security\nUbuntu:noble-backports\nArmbian:noble\nAutomatic-Reboot \"false\"\n")
	writeFixtureFile(t, filepath.Join(rootfs, "lib/systemd/system/apt-daily-upgrade.timer"), "[Timer]\n")
	if err := os.MkdirAll(filepath.Join(rootfs, "etc/systemd/system/timers.target.wants"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/lib/systemd/system/apt-daily-upgrade.timer", filepath.Join(rootfs, "etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer")); err != nil {
		t.Fatal(err)
	}
	writeFixtureFile(t, filepath.Join(rootfs, "etc/machine-id"), "")
	writeFixtureFile(t, filepath.Join(rootfs, "var/lib/dpkg/status"), installedPackages())
	writeFixtureFile(t, filepath.Join(rootfs, "etc/modules-load.d/k3s.conf"), "overlay\nbr_netfilter\n")
	writeFixtureFile(t, filepath.Join(rootfs, "etc/sysctl.d/99-k3s.conf"), "net.ipv4.ip_forward = 1\n")
	writeFixtureFile(t, filepath.Join(rootfs, "etc/cloud/cloud.cfg.d/99-ironstone.cfg"), "users: []\n")
	writeFixtureFile(t, filepath.Join(rootfs, "var/lib/cloud/seed/nocloud/user-data"), "#cloud-config\n")
	writeFixtureFile(t, filepath.Join(rootfs, "etc/fstab"), "UUID=root / ext4 defaults 0 1\n")
	writeFixtureFile(t, filepath.Join(rootfs, "etc/systemd/system/k3s.service"), "ConditionPathExists=/etc/rancher/k3s/config.yaml\nConditionPathExists=/etc/rancher/k3s/cluster-token\n")
	writeFixtureFile(t, filepath.Join(rootfs, "usr/local/bin/k3s"), "k3s fixture\n")
	if err := os.Chmod(filepath.Join(rootfs, "usr/local/bin/k3s"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFixtureFile(t, filepath.Join(rootfs, "var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar"), "airgap fixture\n")
	writeFixtureFile(t, filepath.Join(rootfs, "etc/initramfs-tools/scripts/local-premount/nvme-rescan"), "#!/bin/sh\n")
	if err := os.Chmod(filepath.Join(rootfs, "etc/initramfs-tools/scripts/local-premount/nvme-rescan"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeInitramfsFixture(t, filepath.Join(rootfs, "boot/initrd.img-fixture"))

	binaryHash := fixtureHash(t, filepath.Join(rootfs, "usr/local/bin/k3s"))
	airgapHash := fixtureHash(t, filepath.Join(rootfs, "var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar"))
	manifest := filepath.Join(root, "manifest.json")
	data, err := json.Marshal(Manifest{K3sVersion: "v1.36.3+k3s1", Files: map[string]FileMetadata{
		"k3s_binary": {Filename: "k3s-arm64", SHA256: binaryHash},
		"k3s_airgap": {Filename: "k3s-airgap-images-arm64.tar", SHA256: airgapHash},
	}})
	if err != nil {
		t.Fatal(err)
	}
	writeFixtureFile(t, manifest, string(data))
	return verificationFixture{root: root, rootfs: rootfs, manifest: manifest}
}

func installedPackages() string {
	packages := []string{"cloud-init", "conntrack", "iptables", "ipvsadm", "multipath-tools", "nfs-common", "nvme-cli", "open-iscsi", "unattended-upgrades"}
	paragraphs := make([]string, 0, len(packages))
	for _, pkg := range packages {
		paragraphs = append(paragraphs, "Package: "+pkg+"\nStatus: install ok installed")
	}
	return strings.Join(paragraphs, "\n\n") + "\n"
}

func fixtureHash(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func writeInitramfsFixture(t *testing.T, path string) {
	t.Helper()
	var archive bytes.Buffer
	writeNewcEntry(t, &archive, "scripts/local-premount/nvme-rescan", []byte("#!/bin/sh\n"))
	writeNewcEntry(t, &archive, "TRAILER!!!", nil)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	writer := gzip.NewWriter(file)
	if _, err := writer.Write(archive.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}

func writeNewcEntry(t *testing.T, archive *bytes.Buffer, name string, contents []byte) {
	t.Helper()
	namesize := len(name) + 1
	header := fmt.Sprintf("070701%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x", 0, 0o100644, 0, 0, 1, 0, len(contents), 0, 0, 0, 0, namesize, 0)
	if len(header) != 110 {
		t.Fatalf("newc header length = %d", len(header))
	}
	archive.WriteString(header)
	archive.WriteString(name)
	archive.WriteByte(0)
	for archive.Len()%4 != 0 {
		archive.WriteByte(0)
	}
	archive.Write(contents)
	for archive.Len()%4 != 0 {
		archive.WriteByte(0)
	}
}
