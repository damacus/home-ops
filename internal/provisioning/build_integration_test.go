package provisioning

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type buildFixture struct {
	root     string
	armbian  string
	oldImage string
}

func TestBuildAndArtifactValidationIntegration(t *testing.T) {
	fixture := newBuildFixture(t, false)
	server := k3sPayloadServer(t)
	defer server.Close()
	withBuildEnvironment(t, server.URL)

	var stdout, stderr bytes.Buffer
	if code := RunCLI(
		fixture.root,
		[]string{"build"},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); code != 0 {
		t.Fatalf("build exit code = %d, stderr = %s", code, stderr.String())
	}
	image := strings.TrimSpace(stdout.String())
	if !strings.HasSuffix(image, ".img.xz") {
		t.Fatalf("build output = %q", image)
	}
	if _, err := os.Stat(image); err != nil {
		t.Fatalf("built image is missing: %v", err)
	}
	existing, err := os.ReadFile(filepath.Join(fixture.armbian, "userpatches", "existing.txt"))
	if err != nil || string(existing) != "preserve" {
		t.Fatalf("pre-existing userpatches were not restored: %q, %v", existing, err)
	}

	stdout.Reset()
	stderr.Reset()
	if code := RunCLI(
		fixture.root,
		[]string{"artifact", "validate", image},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); code != 0 {
		t.Fatalf("artifact validation exit code = %d, stderr = %s", code, stderr.String())
	}
	var validated artifactValidation
	if err := json.Unmarshal(stdout.Bytes(), &validated); err != nil {
		t.Fatalf("artifact validation JSON: %v", err)
	}
	if validated.Image != image || validated.ReleaseID == "" {
		t.Fatalf("unexpected validation result: %#v", validated)
	}

	manifestData, err := os.ReadFile(validated.Manifest)
	if err != nil {
		t.Fatal(err)
	}
	manifestData = bytes.Replace(manifestData, []byte(`"sha256": "`), []byte(`"sha256": "0`), 1)
	if err := os.WriteFile(validated.Manifest, manifestData, 0o644); err != nil {
		t.Fatal(err)
	}
	stdout.Reset()
	stderr.Reset()
	if code := RunCLI(
		fixture.root,
		[]string{"artifact", "validate", image},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); code == 0 {
		t.Fatal("artifact validation accepted corrupted manifest metadata")
	}
}

func TestBuildFailureRestoresUserpatchesAndPublishesNothing(t *testing.T) {
	fixture := newBuildFixture(t, true)
	server := k3sPayloadServer(t)
	defer server.Close()
	withBuildEnvironment(t, server.URL)

	var stdout, stderr bytes.Buffer
	if code := RunCLI(
		fixture.root,
		[]string{"build"},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); code == 0 {
		t.Fatal("failed fake build returned success")
	}
	existing, err := os.ReadFile(filepath.Join(fixture.armbian, "userpatches", "existing.txt"))
	if err != nil || string(existing) != "preserve" {
		t.Fatalf("pre-existing userpatches were not restored: %q, %v", existing, err)
	}
	artifacts, err := filepath.Glob(filepath.Join(fixture.root, "provisioning/artifacts/*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 0 {
		t.Fatalf("failed build published artifacts: %v", artifacts)
	}
}

func TestArmbianCheckAllowsGeneratedStateAndRejectsDirtySource(t *testing.T) {
	fixture := newBuildFixture(t, false)
	for _, path := range []string{
		"Dockerfile",
		".dockerignore",
		"cache/generated",
		"output/images/generated.img.xz",
		".tmp/generated",
	} {
		writeFixtureFile(t, filepath.Join(fixture.armbian, path), "generated")
	}
	var stdout, stderr bytes.Buffer
	if code := RunCLI(
		fixture.root,
		[]string{"armbian", "check", "docker-purge"},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); code != 0 {
		t.Fatalf("generated state rejected: code=%d stderr=%s", code, stderr.String())
	}
	writeFixtureFile(
		t,
		filepath.Join(fixture.armbian, "lib/functions/cli/commands.sh"),
		`#!/bin/sh
["build"]="modified"
["docker-purge"]="docker"
`,
	)
	stdout.Reset()
	stderr.Reset()
	if code := RunCLI(
		fixture.root,
		[]string{"armbian", "check", "docker-purge"},
		strings.NewReader(""),
		&stdout,
		&stderr,
	); code == 0 {
		t.Fatal("dirty Armbian source was accepted")
	}
}

func newBuildFixture(t *testing.T, failBuild bool) buildFixture {
	t.Helper()
	root := t.TempDir()
	armbian := filepath.Join(root, "provisioning/armbian-build/armbian-build-repo")
	writeFixtureFile(t, filepath.Join(root, "go.mod"), "module github.com/damacus/home-ops\ngo 1.26.6\n")
	writeFixtureFile(t, filepath.Join(root, "kubernetes/apps/system-upgrade/k3s/app/plan.yaml"), `spec:
  version: v1.36.3+k3s1
---
spec:
  version: v1.36.3+k3s1
`)
	writeFixtureFile(t, filepath.Join(root, "provisioning/armbian-build/userpatches/base.txt"), "base")
	writeFixtureFile(t, filepath.Join(armbian, ".gitignore"), "Dockerfile\n.dockerignore\ncache/\noutput/\n.tmp/\n")
	writeFixtureFile(t, filepath.Join(armbian, "lib/functions/cli/commands.sh"), `#!/bin/sh
["build"]="standard_build"
["docker-purge"]="docker"
`)
	writeFixtureFile(t, filepath.Join(armbian, "lib/functions/image/partitioning.sh"), "FIXED_IMAGE_SIZE=1\n")
	compile := `#!/bin/sh
set -eu
mkdir -p output/images
cp userpatches/overlay/usr/local/bin/k3s output/injected-k3s
printf 'new image' > output/images/new.img.xz
if [ "${FAKE_COMPILE_FAIL:-}" = "1" ]; then exit 42; fi
`
	writeFixtureFile(t, filepath.Join(armbian, "compile.sh"), compile)
	writeFixtureFile(t, filepath.Join(armbian, "userpatches/existing.txt"), "preserve")
	commitFixtureRepo(t, armbian)
	armbianCommit := fixtureCommand(t, armbian, "git", "rev-parse", "HEAD")
	commitFixtureRepo(t, root)
	if indexed := fixtureCommand(t, root, "git", "ls-files", "--stage", "--", "provisioning/armbian-build/armbian-build-repo"); !strings.Contains(indexed, armbianCommit) {
		t.Fatalf("fixture gitlink = %q, want %s", indexed, armbianCommit)
	}
	if failBuild {
		t.Setenv("FAKE_COMPILE_FAIL", "1")
	}
	oldImage := filepath.Join(armbian, "output/images/old.img.xz")
	writeFixtureFile(t, oldImage, "old image")
	oldTime := time.Now().Add(-time.Hour)
	if err := os.Chtimes(oldImage, oldTime, oldTime); err != nil {
		t.Fatal(err)
	}
	return buildFixture{root: root, armbian: armbian, oldImage: oldImage}
}

func k3sPayloadServer(t *testing.T) *httptest.Server {
	t.Helper()
	binary := []byte("k3s binary")
	airgap := []byte("k3s airgap")
	hash := func(data []byte) string {
		digest := sha256.Sum256(data)
		return hex.EncodeToString(digest[:])
	}
	var server *httptest.Server
	defer func() {
		if recovered := recover(); recovered != nil {
			t.Skipf("local HTTP listener unavailable: %v", recovered)
		}
	}()
	server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch filepath.Base(request.URL.Path) {
		case "k3s-arm64":
			_, _ = writer.Write(binary)
		case "k3s-airgap-images-arm64.tar":
			_, _ = writer.Write(airgap)
		case "sha256sum-arm64.txt":
			_, _ = fmt.Fprintf(writer, "%s  k3s-arm64\n%s  k3s-airgap-images-arm64.tar\n", hash(binary), hash(airgap))
		default:
			http.NotFound(writer, request)
		}
	}))
	return server
}

func withBuildEnvironment(t *testing.T, serverURL string) {
	t.Helper()
	t.Setenv("PROVISIONING_K3S_RELEASE_BASE_URL", serverURL)
	bin := t.TempDir()
	writeFixtureFile(t, filepath.Join(bin, "docker"), "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(filepath.Join(bin, "docker"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func commitFixtureRepo(t *testing.T, directory string) {
	t.Helper()
	fixtureCommand(t, directory, "git", "init", "-q")
	fixtureCommand(t, directory, "git", "config", "user.email", "test@example.invalid")
	fixtureCommand(t, directory, "git", "config", "user.name", "Fixture")
	fixtureCommand(t, directory, "git", "config", "commit.gpgsign", "false")
	fixtureCommand(t, directory, "git", "add", "-A")
	fixtureCommand(t, directory, "git", "commit", "-q", "-m", "fixture")
}

func fixtureCommand(t *testing.T, directory string, name string, args ...string) string {
	t.Helper()
	command := exec.Command(name, args...)
	command.Dir = directory
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %s: %v\n%s", name, strings.Join(args, " "), err, output)
	}
	return strings.TrimSpace(string(output))
}

func writeFixtureFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
	if strings.HasSuffix(filepath.Base(path), "compile.sh") || filepath.Base(path) == "docker" {
		if err := os.Chmod(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
}
