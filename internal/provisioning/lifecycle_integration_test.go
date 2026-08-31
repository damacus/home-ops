package provisioning

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const lifecycleToken = "super-secret-token"

func TestLifecycleDryRunDoesNotReadTokenAndDerivesNodeIP(t *testing.T) {
	fixture := newLifecycleFixture(t, "waitready")
	result := fixture.run(t, "enrol", "target.example", "--dry-run")
	if result.exitCode != 0 {
		t.Fatalf("dry-run exit = %d, stderr = %s", result.exitCode, result.stderr)
	}
	var plan map[string]any
	if err := json.Unmarshal([]byte(result.stdout), &plan); err != nil {
		t.Fatalf("parse dry-run JSON: %v", err)
	}
	if got := plan["node_ip"]; got != "10.0.0.44" {
		t.Fatalf("derived node_ip = %#v, want 10.0.0.44", got)
	}
	fixture.assertLogExcludes(t, "cat /var/lib/rancher/k3s/server/token", "delete node", "install -m 0600")
}

func TestLifecycleRefusesReadyReplacementBeforeTokenAccess(t *testing.T) {
	fixture := newLifecycleFixture(t, "existing-ready")
	result := fixture.run(t, "enrol", "target.example", "--replace")
	if result.exitCode == 0 || !strings.Contains(result.stderr, "refusing to replace Ready Kubernetes node") {
		t.Fatalf("Ready replacement result = exit %d, stderr %q", result.exitCode, result.stderr)
	}
	fixture.assertLogExcludes(t, "server/token", "delete node")
}

func TestLifecycleRejectedReplacementNeverReadsToken(t *testing.T) {
	fixture := newLifecycleFixture(t, "existing-notready")
	withoutOverride := fixture.run(t, "enrol", "target.example")
	if withoutOverride.exitCode == 0 || !strings.Contains(withoutOverride.stderr, "pass --replace explicitly") {
		t.Fatalf("replacement without override result = exit %d, stderr %q", withoutOverride.exitCode, withoutOverride.stderr)
	}
	if withoutOverride.stdout != "" {
		t.Fatalf("rejected replacement emitted a result document")
	}
	fixture.assertLogExcludes(t, "cat /var/lib/rancher/k3s/server/token", "delete node")

	fixture = newLifecycleFixture(t, "existing-notready")
	wrongConfirmation := fixture.runWithInput(t, "replace another-node\n", "enrol", "target.example", "--replace", "--node-ip", "10.0.0.77")
	if wrongConfirmation.exitCode == 0 || !strings.Contains(wrongConfirmation.stderr, "confirmation did not match") {
		t.Fatalf("replacement with wrong confirmation result = exit %d, stderr %q", wrongConfirmation.exitCode, wrongConfirmation.stderr)
	}
	if wrongConfirmation.stdout != "" {
		t.Fatalf("unconfirmed replacement emitted a result document")
	}
	fixture.assertLogExcludes(t, "cat /var/lib/rancher/k3s/server/token", "delete node")
}

func TestLifecycleRejectsUnsafeSanitisedConfigBeforeTokenAccess(t *testing.T) {
	fixture := newLifecycleFixture(t, "waitready")
	fixture.setEnv(t, "YQ_UNSAFE", "true")
	result := fixture.run(t, "enrol", "target.example", "--node-ip", "10.0.0.77")
	if result.exitCode == 0 || !strings.Contains(result.stderr, "unsafe authentication") {
		t.Fatalf("unsafe config result = exit %d, stderr %q", result.exitCode, result.stderr)
	}
	fixture.assertLogExcludes(t, "cat /var/lib/rancher/k3s/server/token", "delete node", "install -m 0600")
}

func TestLifecycleReplacementConfirmsBeforeTokenAndDeletion(t *testing.T) {
	fixture := newLifecycleFixture(t, "existing-notready")
	result := fixture.runWithInput(t, "replace node-abcdef\n", "enrol", "target.example", "--replace", "--node-ip", "10.0.0.77")
	if result.exitCode != 0 {
		t.Fatalf("replacement exit = %d, stderr = %s", result.exitCode, result.stderr)
	}
	if strings.Contains(result.stdout, lifecycleToken) || strings.Contains(result.stderr, lifecycleToken) {
		t.Fatalf("replacement output exposed the server token")
	}
	assertJSONResult(t, result.stdout, "node", "node-abcdef")
	log := fixture.log(t)
	token := strings.Index(log, "server/token")
	deleteNode := strings.Index(log, "delete node node-abcdef")
	if !strings.Contains(result.stderr, "Type replace node-abcdef") || token < 0 || deleteNode < 0 || !(token < deleteNode) {
		t.Fatalf("replacement did not confirm before its token and deletion sequence")
	}
	if !strings.Contains(log, "10.0.0.77") {
		t.Fatalf("explicit node IP was not passed to source-config sanitisation")
	}
}

func TestLifecycleRejectsExplicitNodeIPOutsideRouteInterface(t *testing.T) {
	fixture := newLifecycleFixture(t, "waitready")
	result := fixture.run(t, "enrol", "target.example", "--node-ip", "10.0.0.78", "--dry-run")
	if result.exitCode == 0 || !strings.Contains(result.stderr, "node IP 10.0.0.78 is not assigned to interface eth0") {
		t.Fatalf("explicit route validation result = exit %d, stderr %q", result.exitCode, result.stderr)
	}
	fixture.assertLogExcludes(t, "cat /var/lib/rancher/k3s/server/token", "delete node", "install -m 0600")
}

func TestLifecycleAcceptsAssignedExplicitNodeIPWithoutRoutePreferredSource(t *testing.T) {
	fixture := newLifecycleFixture(t, "waitready")
	fixture.setEnv(t, "ROUTE_NO_PREFSRC", "true")
	result := fixture.run(t, "enrol", "target.example", "--node-ip", "10.0.0.77", "--dry-run")
	if result.exitCode != 0 {
		t.Fatalf("explicit route result = exit %d, stderr %q", result.exitCode, result.stderr)
	}
	assertJSONResult(t, result.stdout, "node_ip", "10.0.0.77")
}

func TestLifecycleRejectsRouteSourceMissingFromInterface(t *testing.T) {
	fixture := newLifecycleFixture(t, "waitready")
	fixture.setEnv(t, "ROUTE_ADDRESS_PRESENT", "false")
	result := fixture.run(t, "enrol", "target.example", "--dry-run")
	if result.exitCode == 0 || !strings.Contains(result.stderr, "not assigned to interface eth0") {
		t.Fatalf("route validation result = exit %d, stderr %q", result.exitCode, result.stderr)
	}
}

func TestLifecycleReadinessTimeoutRedactsBoundedLogs(t *testing.T) {
	fixture := newLifecycleFixture(t, "never-ready")
	fixture.setEnv(t, "JOURNAL_SIZE", "9000")
	result := fixture.run(t, "enrol", "target.example", "--node-ip", "10.0.0.77", "--ready-timeout", "0s")
	if result.exitCode == 0 || !strings.Contains(result.stderr, "bounded k3s logs") {
		t.Fatalf("timeout result = exit %d, stderr %q", result.exitCode, result.stderr)
	}
	if strings.Contains(result.stderr, lifecycleToken) || !strings.Contains(result.stderr, "<redacted>") {
		t.Fatalf("timeout logs did not redact the server token")
	}
	if len(result.stderr) > 8400 || !strings.Contains(result.stderr, "expected-log-tail") {
		t.Fatalf("timeout diagnostics did not retain a bounded log tail")
	}
}

func TestLifecycleTokenTransferFailureLeavesNoFinalFilesAndRetrySucceeds(t *testing.T) {
	fixture := newLifecycleFixture(t, "replacement-retry")
	fixture.setEnv(t, "TOKEN_TRANSFER_FAIL", "true")
	failed := fixture.runWithInput(t, "replace node-abcdef\n", "enrol", "target.example", "--replace", "--node-ip", "10.0.0.77")
	if failed.exitCode == 0 || failed.stdout != "" {
		t.Fatalf("token transfer failure result = exit %d, stdout %q", failed.exitCode, failed.stdout)
	}
	if strings.Contains(failed.stderr, lifecycleToken) {
		t.Fatalf("token transfer failure exposed the server token")
	}
	fixture.assertTargetStateAbsent(t, "final-config", "final-token", "staged-config", "staged-token")
	fixture.assertLogExcludes(t, "enable --now k3s.service")

	fixture.setEnv(t, "TOKEN_TRANSFER_FAIL", "false")
	retry := fixture.run(t, "enrol", "target.example", "--node-ip", "10.0.0.77")
	if retry.exitCode != 0 {
		t.Fatalf("enrol retry exit = %d, stderr = %s", retry.exitCode, retry.stderr)
	}
	assertJSONResult(t, retry.stdout, "node", "node-abcdef")
	fixture.assertTargetStatePresent(t, "final-config", "final-token")
	log := fixture.log(t)
	if strings.Count(log, "kubectl delete node node-abcdef") != 1 || strings.Count(log, "enable --now k3s.service") != 1 {
		t.Fatalf("retry repeated a destructive replacement operation")
	}
}

func TestLifecycleRetirementPreflightAndOrder(t *testing.T) {
	fixture := newLifecycleFixture(t, "waitready")
	fixture.setEnv(t, "RETIRE_UNIT", "missing")
	refused := fixture.runWithInput(t, "node-abcdef\n", "retire", "node-abcdef", "target.example")
	if refused.exitCode == 0 || !strings.Contains(refused.stderr, "k3s.service") {
		t.Fatalf("retirement preflight result = exit %d, stderr %q", refused.exitCode, refused.stderr)
	}
	if refused.stdout != "" {
		t.Fatalf("rejected retirement emitted a result document")
	}
	fixture.assertLogExcludes(t, "kubectl drain", "delete node", "disable --now")

	fixture = newLifecycleFixture(t, "waitready")
	fixture.setEnv(t, "RETIRE_NODE_STATE", "present")
	result := fixture.runWithInput(t, "node-abcdef\n", "retire", "node-abcdef", "target.example")
	if result.exitCode != 0 {
		t.Fatalf("retirement exit = %d, stderr = %s", result.exitCode, result.stderr)
	}
	assertJSONResult(t, result.stdout, "node", "node-abcdef")
	log := fixture.log(t)
	identity := strings.Index(log, "hostname -s")
	drain := strings.Index(log, "kubectl drain node-abcdef")
	stop := strings.Index(log, "disable --now k3s.service")
	deleteNode := strings.Index(log, "delete node node-abcdef")
	remove := strings.Index(log, "rm -rf /etc/rancher/k3s /var/lib/rancher/k3s")
	if !strings.Contains(result.stderr, "Type node-abcdef") || identity < 0 || drain < 0 || stop < 0 || deleteNode < 0 || remove < 0 || !(identity < drain && drain < stop && stop < deleteNode && deleteNode < remove) {
		t.Fatalf("retirement command order did not preserve its safety boundary")
	}
}

func TestLifecycleRetirementRetriesCleanupAfterNodeDeletion(t *testing.T) {
	fixture := newLifecycleFixture(t, "waitready")
	fixture.setEnv(t, "RETIRE_NODE_STATE", "present")
	fixture.setEnv(t, "RETIRE_CLEANUP_FAIL", "true")
	failed := fixture.runWithInput(t, "node-abcdef\n", "retire", "node-abcdef", "target.example")
	if failed.exitCode == 0 || failed.stdout != "" {
		t.Fatalf("cleanup failure result = exit %d, stdout %q", failed.exitCode, failed.stdout)
	}
	if !strings.Contains(failed.stderr, "cleanup failed") {
		t.Fatalf("cleanup failure was not reported: %q", failed.stderr)
	}

	fixture.setEnv(t, "RETIRE_NODE_STATE", "absent")
	fixture.setEnv(t, "RETIRE_CLEANUP_FAIL", "false")
	retry := fixture.runWithInput(t, "node-abcdef\n", "retire", "node-abcdef", "target.example")
	if retry.exitCode != 0 {
		t.Fatalf("retirement retry exit = %d, stderr = %s", retry.exitCode, retry.stderr)
	}
	assertJSONResult(t, retry.stdout, "node", "node-abcdef")
	log := fixture.log(t)
	for _, path := range []string{"/etc/rancher/k3s", "/var/lib/rancher/k3s", "/var/lib/kubelet", "/var/lib/cni", "/etc/cni/net.d", "/etc/rancher/node"} {
		if !strings.Contains(log, path) {
			t.Fatalf("retirement cleanup did not include %s", path)
		}
	}
	if strings.Count(log, "kubectl drain node-abcdef") != 1 || strings.Count(log, "kubectl delete node node-abcdef") != 1 {
		t.Fatalf("retirement retry repeated drain or node deletion")
	}
}

func TestMiseEnrolDryRunForwardsNodeIPToGoCommand(t *testing.T) {
	fixture := newLifecycleFixture(t, "waitready")
	fixture.setEnv(t, "MISE_PROJECT_ROOT", moduleRoot(t))
	command := exec.Command("mise", "run", "provisioning:enrol", "--", "target.example", "--node-ip", "10.0.0.77", "--dry-run")
	command.Dir = moduleRoot(t)
	command.Env = append(os.Environ(), fixture.env...)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		t.Fatalf("mise enrol dry-run: %v, stderr = %s", err, stderr.String())
	}
	assertJSONResult(t, stdout.String(), "node_ip", "10.0.0.77")
	fixture.assertLogExcludes(t, "cat /var/lib/rancher/k3s/server/token", "delete node", "install -m 0600")
}

type lifecycleFixture struct {
	t      *testing.T
	root   string
	bin    string
	binDir string
	env    []string
}

type lifecycleResult struct {
	exitCode int
	stdout   string
	stderr   string
}

func newLifecycleFixture(t *testing.T, nodeMode string) *lifecycleFixture {
	t.Helper()
	root := t.TempDir()
	writeFixtureFile(t, filepath.Join(root, "kubernetes/apps/system-upgrade/k3s/app/plan.yaml"), `version: v1.36.3+k3s1
---
version: v1.36.3+k3s1
`)
	bin := filepath.Join(root, "provisioning")
	command := exec.Command("go", "build", "-o", bin, "./cmd/provisioning")
	command.Dir = moduleRoot(t)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("build provisioning command: %v\n%s", err, output)
	}
	binDir := filepath.Join(root, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, script := range map[string]string{
		"kubectl": lifecycleKubectlScript,
		"ssh":     lifecycleSSHScript,
		"yq":      lifecycleYQScript,
	} {
		writeFixtureFile(t, filepath.Join(binDir, name), script)
		if err := os.Chmod(filepath.Join(binDir, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return &lifecycleFixture{t: t, root: root, bin: bin, binDir: binDir, env: []string{
		"MISE_PROJECT_ROOT=" + root,
		"PATH=" + binDir + ":" + os.Getenv("PATH"),
		"CALL_LOG=" + filepath.Join(root, "calls.log"),
		"TARGET_STATE=" + filepath.Join(root, "target-state"),
		"NODE_MODE=" + nodeMode,
		"ROUTE_ADDRESS_PRESENT=true",
		"LIFECYCLE_TOKEN=" + lifecycleToken,
	}}
}

func (f *lifecycleFixture) setEnv(t *testing.T, key, value string) {
	t.Helper()
	prefix := key + "="
	for i, entry := range f.env {
		if strings.HasPrefix(entry, prefix) {
			f.env[i] = prefix + value
			return
		}
	}
	f.env = append(f.env, prefix+value)
}

func (f *lifecycleFixture) run(t *testing.T, args ...string) lifecycleResult {
	t.Helper()
	return f.runWithInput(t, "", args...)
}

func (f *lifecycleFixture) runWithInput(t *testing.T, input string, args ...string) lifecycleResult {
	t.Helper()
	command := exec.Command(f.bin, args...)
	command.Env = append(os.Environ(), f.env...)
	command.Stdin = strings.NewReader(input)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	result := lifecycleResult{stdout: stdout.String(), stderr: stderr.String()}
	if exit, ok := err.(*exec.ExitError); ok {
		result.exitCode = exit.ExitCode()
	} else if err != nil {
		t.Fatalf("run provisioning command: %v", err)
	}
	return result
}

func (f *lifecycleFixture) log(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(f.root, "calls.log"))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func (f *lifecycleFixture) assertLogExcludes(t *testing.T, values ...string) {
	t.Helper()
	log := f.log(t)
	for _, value := range values {
		if strings.Contains(log, value) {
			t.Fatalf("command log unexpectedly includes %q", value)
		}
	}
}

func (f *lifecycleFixture) assertTargetStateAbsent(t *testing.T, names ...string) {
	t.Helper()
	for _, name := range names {
		if _, err := os.Stat(filepath.Join(f.root, "target-state", name)); err == nil {
			t.Fatalf("target state %s is still present", name)
		} else if !os.IsNotExist(err) {
			t.Fatal(err)
		}
	}
}

func (f *lifecycleFixture) assertTargetStatePresent(t *testing.T, names ...string) {
	t.Helper()
	for _, name := range names {
		if _, err := os.Stat(filepath.Join(f.root, "target-state", name)); err != nil {
			t.Fatalf("target state %s is missing: %v", name, err)
		}
	}
}

func assertJSONResult(t *testing.T, output, key, want string) {
	t.Helper()
	var result map[string]any
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		t.Fatalf("successful stdout was not one JSON result: %v", err)
	}
	if got := result[key]; got != want {
		t.Fatalf("JSON result %s = %#v, want %q", key, got, want)
	}
}

func moduleRoot(t *testing.T) string {
	t.Helper()
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	return root
}

const lifecycleKubectlScript = `#!/bin/sh
set -eu
printf 'kubectl %s\n' "$*" >> "$CALL_LOG"
case "$*" in
  "get --raw=/readyz") echo ok ;;
  "get nodes -o json") printf '%s\n' '{"items":[{"metadata":{"name":"source","labels":{"node-role.kubernetes.io/control-plane":"","node-role.kubernetes.io/etcd":""}},"status":{"conditions":[{"type":"Ready","status":"True"}],"addresses":[{"type":"InternalIP","address":"10.0.0.10"}]}}]}' ;;
  "config view --minify -o json") printf '%s\n' '{"clusters":[{"cluster":{"server":"https://10.0.0.1:6443"}}]}' ;;
  *"get node node-abcdef"*)
    if test -n "${RETIRE_NODE_STATE:-}"; then
      if test "$RETIRE_NODE_STATE" = present; then printf '%s\n' '{"metadata":{"name":"node-abcdef"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}'; fi
      exit 0
    fi
    count_file="$CALL_LOG.get-node"
    count=0
    test -f "$count_file" && count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    case "$NODE_MODE:$count" in
      existing-ready:*) printf '%s\n' '{"metadata":{"name":"node-abcdef","uid":"old"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' ;;
      existing-notready:1) printf '%s\n' '{"metadata":{"name":"node-abcdef","uid":"old"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}' ;;
      existing-notready:2|existing-notready:3) printf '%s\n' '{"metadata":{"name":"node-abcdef","labels":{"node-role.kubernetes.io/control-plane":"","node-role.kubernetes.io/etcd":""}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' ;;
      replacement-retry:1) printf '%s\n' '{"metadata":{"name":"node-abcdef","uid":"old"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}' ;;
      replacement-retry:3|replacement-retry:4) printf '%s\n' '{"metadata":{"name":"node-abcdef","labels":{"node-role.kubernetes.io/control-plane":"","node-role.kubernetes.io/etcd":""}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' ;;
      waitready:2|waitready:3|waitready:4) printf '%s\n' '{"metadata":{"name":"node-abcdef","labels":{"node-role.kubernetes.io/control-plane":"","node-role.kubernetes.io/etcd":""}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' ;;
    esac ;;
  "delete node node-abcdef") echo 'kubectl progress' ;;
  "drain node-abcdef --ignore-daemonsets --delete-emptydir-data") echo 'kubectl progress' ;;
  *) echo "unexpected kubectl invocation: $*" >&2; exit 1 ;;
esac
`

const lifecycleSSHScript = `#!/bin/sh
set -eu
printf 'ssh %s\n' "$*" >> "$CALL_LOG"
case "$*" in
  *"hostname -s") echo node-abcdef ;;
  *"sudo -n true") : ;;
  *"test -s /etc/machine-id") : ;;
  *"cloud-init status --wait") echo 'status: done' ;;
  *"/usr/local/bin/k3s --version") echo 'k3s version v1.36.3+k3s1 (fixture)' ;;
  *"systemctl is-enabled k3s.service"*) echo disabled ;;
  *"systemctl is-active k3s.service"*) echo inactive ;;
  *"sudo test ! -e /etc/rancher/k3s/config.yaml"*) : ;;
  *"ip -j route get "*)
    if test "${ROUTE_NO_PREFSRC:-false}" = true; then echo '[{"dev":"eth0"}]'; else echo '[{"dev":"eth0","prefsrc":"10.0.0.44"}]'; fi ;;
  *"ip -j addr show dev eth0"*)
    if test "$ROUTE_ADDRESS_PRESENT" = true; then echo '[{"ifname":"eth0","addr_info":[{"family":"inet","local":"10.0.0.44"},{"family":"inet","local":"10.0.0.77"}]}]'; else echo '[{"ifname":"eth0","addr_info":[]}]'; fi ;;
  *"cat /etc/rancher/k3s/config.yaml") echo 'write-kubeconfig-mode: 0644' ;;
  *"cat /var/lib/rancher/k3s/server/token") echo "$LIFECYCLE_TOKEN" ;;
  *"journalctl -u k3s.service"*)
    size="${JOURNAL_SIZE:-0}"
    i=0
    printf 'log prefix '
    while test "$i" -lt "$size"; do printf x; i=$((i + 1)); done
    printf ' %s expected-log-tail\n' "$LIFECYCLE_TOKEN" ;;
  *"systemctl cat k3s.service"*) test "${RETIRE_UNIT:-present}" != missing ;;
  *"mv /etc/rancher/k3s/.enrol-staging/config.yaml"*) mkdir -p "$TARGET_STATE"; touch "$TARGET_STATE/final-config" "$TARGET_STATE/final-token"; rm -f "$TARGET_STATE/staged-config" "$TARGET_STATE/staged-token" ;;
  *".enrol-staging/config.yaml"*) mkdir -p "$TARGET_STATE"; touch "$TARGET_STATE/staged-config"; cat >/dev/null; echo 'ssh progress' ;;
  *"install -d -m 0700"*) mkdir -p "$TARGET_STATE"; touch "$TARGET_STATE/final-config"; cat >/dev/null; printf 'stdin-redacted\n' >> "$CALL_LOG"; echo 'ssh progress' ;;
  *".enrol-staging/cluster-token"*)
    if test "${TOKEN_TRANSFER_FAIL:-false}" = true; then echo 'token transfer failed' >&2; exit 1; fi
    mkdir -p "$TARGET_STATE"; touch "$TARGET_STATE/staged-token"; cat >/dev/null ;;
  *"install -m 0600 /dev/stdin /etc/rancher/k3s/cluster-token"*)
    if test "${TOKEN_TRANSFER_FAIL:-false}" = true; then echo 'token transfer failed' >&2; exit 1; fi
    mkdir -p "$TARGET_STATE"; touch "$TARGET_STATE/final-token"; cat >/dev/null ;;
  *"rm -rf /etc/rancher/k3s/.enrol-staging"*) rm -f "$TARGET_STATE/staged-config" "$TARGET_STATE/staged-token" ;;
  *"systemctl enable --now k3s.service") echo 'ssh progress' ;;
  *"systemctl disable --now k3s.service") echo 'ssh progress' ;;
  *"rm -rf /etc/rancher/k3s"*)
    if test "${RETIRE_CLEANUP_FAIL:-false}" = true; then echo 'cleanup failed' >&2; exit 1; fi
    echo 'ssh progress' ;;
  *) echo "unexpected ssh invocation: $*" >&2; exit 1 ;;
esac
`

const lifecycleYQScript = `#!/bin/sh
set -eu
printf 'yq %s\n' "$*" >> "$CALL_LOG"
cat >/dev/null
if test "${YQ_UNSAFE:-false}" = true; then
  printf '%s\n' 'anonymous-auth: true'
  exit 0
fi
printf '%s\n' 'server: https://10.0.0.1:6443'
printf '%s\n' 'token-file: /etc/rancher/k3s/cluster-token'
`
