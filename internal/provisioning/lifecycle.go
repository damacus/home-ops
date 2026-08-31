package provisioning

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

const (
	clusterTokenPath = "/var/lib/rancher/k3s/server/token"
	targetTokenPath  = "/etc/rancher/k3s/cluster-token"
	enrolStagePath   = "/etc/rancher/k3s/.enrol-staging"
)

var retiredClusterStatePaths = []string{
	"/etc/rancher/k3s",
	"/var/lib/rancher/k3s",
	"/var/lib/kubelet",
	"/var/lib/cni",
	"/etc/cni/net.d",
	"/etc/rancher/node",
}

var bakedNodeName = regexp.MustCompile(`^node-[a-f0-9]{6}$`)

type kubernetesNode struct {
	Metadata struct {
		Name   string            `json:"name"`
		UID    string            `json:"uid"`
		Labels map[string]string `json:"labels"`
	} `json:"metadata"`
	Spec struct {
		Unschedulable bool `json:"unschedulable"`
	} `json:"spec"`
	Status struct {
		Conditions []struct {
			Type   string `json:"type"`
			Status string `json:"status"`
		} `json:"conditions"`
		Addresses []struct {
			Type    string `json:"type"`
			Address string `json:"address"`
		} `json:"addresses"`
	} `json:"status"`
}

type nodeList struct {
	Items []kubernetesNode `json:"items"`
}

type lifecyclePlan struct {
	SourceNode     string         `json:"source_node"`
	SourceHost     string         `json:"source_host"`
	TargetHost     string         `json:"target_host"`
	TargetHostname string         `json:"target_hostname"`
	NodeIP         string         `json:"node_ip"`
	K3sVersion     string         `json:"k3s_version"`
	Replacement    map[string]any `json:"replacement"`
	Actions        []string       `json:"actions"`
	Token          string         `json:"token"`
}

type lifecycleCommandResult struct {
	Node       string   `json:"node"`
	Host       string   `json:"host"`
	SourceNode string   `json:"source_node,omitempty"`
	NodeIP     string   `json:"node_ip,omitempty"`
	Actions    []string `json:"actions"`
	Token      string   `json:"token,omitempty"`
}

func (a *App) runEnrol(ctx context.Context, args []string) error {
	sourceNode, _, err := takeValue(&args, "--source-node")
	if err != nil {
		return err
	}
	nodeIP, hasNodeIP, err := takeValue(&args, "--node-ip")
	if err != nil {
		return err
	}
	readyTimeoutValue, hasReadyTimeout, err := takeValue(&args, "--ready-timeout")
	if err != nil {
		return err
	}
	replace := takeBool(&args, "--replace")
	dryRun := takeBool(&args, "--dry-run")
	if err := requirePositionals(args, 1, "provisioning enrol <host> [--source-node <node>] [--node-ip <IPv4>] [--replace] [--dry-run]"); err != nil {
		return err
	}
	if hasNodeIP && !isIPv4(nodeIP) {
		return usageError{message: "--node-ip must be an IPv4 address"}
	}
	readyTimeout := 5 * time.Minute
	if hasReadyTimeout {
		readyTimeout, err = time.ParseDuration(readyTimeoutValue)
		if err != nil || readyTimeout < 0 {
			return usageError{message: "--ready-timeout must be a non-negative duration"}
		}
	}
	targetHost := args[0]

	if _, err := a.kubectlOutput(ctx, "get", "--raw=/readyz"); err != nil {
		return fmt.Errorf("Kubernetes API is not healthy: %w", err)
	}
	source, err := a.controlPlaneSource(ctx, sourceNode)
	if err != nil {
		return err
	}
	sourceHost, err := nodeAddress(source)
	if err != nil {
		return err
	}
	targetName, err := a.sshOutput(ctx, targetHost, "hostname -s")
	if err != nil {
		return err
	}
	if !bakedNodeName.MatchString(targetName) {
		return fmt.Errorf("target hostname does not match the baked node identity contract: %q", targetName)
	}
	existing, err := a.existingNode(ctx, targetName)
	if err != nil {
		return err
	}
	if existing != nil {
		if nodeReady(*existing) {
			return fmt.Errorf("refusing to replace Ready Kubernetes node %s", targetName)
		}
		if !replace {
			return fmt.Errorf("Kubernetes node %s already exists; pass --replace explicitly", targetName)
		}
	}
	if err := a.enrolTargetPreflight(ctx, targetHost); err != nil {
		return err
	}
	version, err := a.currentK3sVersion()
	if err != nil {
		return err
	}
	targetVersion, err := a.sshOutput(ctx, targetHost, "sudo /usr/local/bin/k3s --version")
	if err != nil {
		return err
	}
	if !strings.Contains(targetVersion, version) {
		return fmt.Errorf("target K3s version does not match %s", version)
	}
	endpoint, err := a.currentAPIEndpoint(ctx)
	if err != nil {
		return err
	}
	if nodeIP, err = a.resolveNodeIP(ctx, targetHost, endpoint, nodeIP, hasNodeIP); err != nil {
		return err
	}
	plan := lifecyclePlan{
		SourceNode:     source.Metadata.Name,
		SourceHost:     sourceHost,
		TargetHost:     targetHost,
		TargetHostname: targetName,
		NodeIP:         nodeIP,
		K3sVersion:     version,
		Actions: []string{
			"install sanitised config mode 0600",
			"install redacted server token mode 0600",
			"enable and start k3s",
		},
		Token: "<redacted>",
	}
	if existing != nil {
		plan.Replacement = nodeState(*existing)
	}
	if dryRun {
		return writeJSON(a.exec.stdout, plan)
	}
	if existing != nil {
		confirmation := "replace " + targetName
		if err := a.requireConfirmation(confirmation, "to delete the NotReady node"); err != nil {
			return err
		}
	}

	sourceConfig, err := a.sshOutput(ctx, sourceHost, "sudo cat /etc/rancher/k3s/config.yaml")
	if err != nil {
		return fmt.Errorf("could not read source K3s config")
	}
	config, err := a.sanitiseK3sConfig(ctx, sourceConfig, endpoint, nodeIP)
	if err != nil {
		return err
	}
	token, err := a.sshOutput(ctx, sourceHost, "sudo cat "+clusterTokenPath)
	if err != nil {
		return fmt.Errorf("could not read source K3s token")
	}
	if token == "" {
		return fmt.Errorf("source node returned an empty K3s token")
	}
	if existing != nil {
		if err := a.exec.runToStderr(ctx, a.paths.repo, nil, "kubectl", "delete", "node", targetName); err != nil {
			return err
		}
	}
	if err := a.stageTargetEnrolFiles(ctx, targetHost, config, token); err != nil {
		return redactLifecycleError(err, token)
	}
	if err := a.exec.runToStderr(ctx, a.paths.repo, nil, "ssh", "pi@"+targetHost, "sudo systemctl enable --now k3s.service"); err != nil {
		return err
	}
	if err := a.waitForEnrolledNode(ctx, targetName, targetHost, token, readyTimeout); err != nil {
		return err
	}
	return writeJSON(a.exec.stdout, lifecycleCommandResult{
		Node:       targetName,
		Host:       targetHost,
		SourceNode: source.Metadata.Name,
		NodeIP:     nodeIP,
		Actions:    plan.Actions,
		Token:      "<redacted>",
	})
}

func (a *App) runRetire(ctx context.Context, args []string) error {
	dryRun := takeBool(&args, "--dry-run")
	if err := requirePositionals(args, 2, "provisioning retire <node> <host> [--dry-run]"); err != nil {
		return err
	}
	node, host := args[0], args[1]
	if dryRun {
		return writeJSON(a.exec.stdout, map[string]any{
			"node": node,
			"host": host,
			"actions": []string{
				"preflight target identity, sudo, and k3s",
				"kubectl drain",
				"disable and stop k3s",
				"kubectl delete node",
				"remove K3s config and state",
			},
		})
	}
	hostname, err := a.sshOutput(ctx, host, "hostname -s")
	if err != nil {
		return err
	}
	if hostname != node {
		return fmt.Errorf("target hostname %q does not match node %q", hostname, node)
	}
	if _, err := a.sshOutput(ctx, host, "sudo -n true"); err != nil {
		return err
	}
	if _, err := a.sshOutput(ctx, host, "systemctl cat k3s.service >/dev/null"); err != nil {
		return fmt.Errorf("target does not provide k3s.service: %w", err)
	}
	if err := a.requireConfirmation(node, "to retire it"); err != nil {
		return err
	}
	existing, err := a.existingNode(ctx, node)
	if err != nil {
		return err
	}
	if existing != nil {
		if err := a.exec.runToStderr(ctx, a.paths.repo, nil, "kubectl", "drain", node, "--ignore-daemonsets", "--delete-emptydir-data"); err != nil {
			return err
		}
	}
	if err := a.exec.runToStderr(ctx, a.paths.repo, nil, "ssh", "pi@"+host, "sudo systemctl disable --now k3s.service"); err != nil {
		return err
	}
	if existing != nil {
		if err := a.exec.runToStderr(ctx, a.paths.repo, nil, "kubectl", "delete", "node", node); err != nil {
			return err
		}
	}
	if err := a.removeRetiredClusterState(ctx, host); err != nil {
		return err
	}
	return writeJSON(a.exec.stdout, lifecycleCommandResult{
		Node: node,
		Host: host,
		Actions: []string{
			"preflight target identity, sudo, and k3s",
			"kubectl drain",
			"disable and stop k3s",
			"kubectl delete node",
			"remove K3s config and state",
		},
	})
}

func (a *App) enrolTargetPreflight(ctx context.Context, host string) error {
	for _, command := range []string{
		"sudo -n true",
		"test -s /etc/machine-id",
	} {
		if _, err := a.sshOutput(ctx, host, command); err != nil {
			return err
		}
	}
	cloudInit, err := a.sshOutput(ctx, host, "cloud-init status --wait")
	if err != nil {
		return err
	}
	if !strings.Contains(cloudInit, "status: done") {
		return fmt.Errorf("target cloud-init has not completed: %s", cloudInit)
	}
	enabled, err := a.sshOutput(ctx, host, "systemctl is-enabled k3s.service 2>/dev/null || true")
	if err != nil {
		return err
	}
	active, err := a.sshOutput(ctx, host, "systemctl is-active k3s.service 2>/dev/null || true")
	if err != nil {
		return err
	}
	if enabled != "disabled" || active != "inactive" {
		return fmt.Errorf("target K3s must be dormant before enrolment: enabled=%s, active=%s", enabled, active)
	}
	_, err = a.sshOutput(ctx, host, "sudo test ! -e /etc/rancher/k3s/config.yaml -a ! -e /etc/rancher/k3s/cluster-token -a ! -e /var/lib/rancher/k3s/server/token -a ! -d /var/lib/rancher/k3s/server/db")
	return err
}

func (a *App) controlPlaneSource(ctx context.Context, selected string) (kubernetesNode, error) {
	output, err := a.kubectlOutput(ctx, "get", "nodes", "-o", "json")
	if err != nil {
		return kubernetesNode{}, err
	}
	var nodes nodeList
	if err := json.Unmarshal([]byte(output), &nodes); err != nil {
		return kubernetesNode{}, fmt.Errorf("parse Kubernetes nodes: %w", err)
	}
	for _, node := range nodes.Items {
		if selected != "" && node.Metadata.Name != selected {
			continue
		}
		if nodeReady(node) && nodeControlPlane(node) {
			return node, nil
		}
	}
	if selected != "" {
		return kubernetesNode{}, fmt.Errorf("requested source node %s is not a Ready control-plane", selected)
	}
	return kubernetesNode{}, fmt.Errorf("no Ready control-plane source node is available")
}

func (a *App) existingNode(ctx context.Context, name string) (*kubernetesNode, error) {
	output, err := a.kubectlOutput(ctx, "get", "node", name, "--ignore-not-found", "--request-timeout=10s", "-o", "json")
	if err != nil {
		return nil, fmt.Errorf("could not inspect existing Kubernetes node %s: %w", name, err)
	}
	if output == "" {
		return nil, nil
	}
	var node kubernetesNode
	if err := json.Unmarshal([]byte(output), &node); err != nil {
		return nil, fmt.Errorf("Kubernetes returned invalid node data for %s: %w", name, err)
	}
	if node.Metadata.Name != name {
		return nil, fmt.Errorf("Kubernetes returned an unexpected node identity for %s", name)
	}
	return &node, nil
}

func (a *App) currentK3sVersion() (string, error) {
	plan, err := os.ReadFile(a.paths.k3sPlan)
	if err != nil {
		return "", fmt.Errorf("read K3s Plans: %w", err)
	}
	return ResolveK3sVersion(plan)
}

func (a *App) currentAPIEndpoint(ctx context.Context) (string, error) {
	output, err := a.kubectlOutput(ctx, "config", "view", "--minify", "-o", "json")
	if err != nil {
		return "", err
	}
	var config struct {
		Clusters []struct {
			Cluster struct {
				Server string `json:"server"`
			} `json:"cluster"`
		} `json:"clusters"`
	}
	if err := json.Unmarshal([]byte(output), &config); err != nil {
		return "", fmt.Errorf("parse Kubernetes API endpoint: %w", err)
	}
	if len(config.Clusters) != 1 || config.Clusters[0].Cluster.Server == "" {
		return "", fmt.Errorf("Kubernetes config does not contain one active API endpoint")
	}
	return config.Clusters[0].Cluster.Server, nil
}

func (a *App) resolveNodeIP(ctx context.Context, host, endpoint, override string, hasOverride bool) (string, error) {
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Hostname() == "" {
		return "", fmt.Errorf("invalid Kubernetes API endpoint %q", endpoint)
	}
	routeOutput, err := a.sshOutput(ctx, host, "ip -j route get "+parsed.Hostname())
	if err != nil {
		return "", err
	}
	var routes []struct {
		Device          string `json:"dev"`
		PreferredSource string `json:"prefsrc"`
	}
	if err := json.Unmarshal([]byte(routeOutput), &routes); err != nil || len(routes) == 0 {
		return "", fmt.Errorf("parse route to Kubernetes API endpoint")
	}
	route := routes[0]
	if route.Device == "" {
		return "", fmt.Errorf("route to Kubernetes API endpoint lacks a device")
	}
	addressesOutput, err := a.sshOutput(ctx, host, "ip -j addr show dev "+route.Device)
	if err != nil {
		return "", err
	}
	var interfaces []struct {
		AddressInfo []struct {
			Family string `json:"family"`
			Local  string `json:"local"`
		} `json:"addr_info"`
	}
	if err := json.Unmarshal([]byte(addressesOutput), &interfaces); err != nil || len(interfaces) == 0 {
		return "", fmt.Errorf("parse addresses for interface %s", route.Device)
	}
	selected := route.PreferredSource
	if hasOverride {
		selected = override
	} else if !isIPv4(selected) {
		return "", fmt.Errorf("route to Kubernetes API endpoint lacks an IPv4 preferred source")
	}
	for _, networkInterface := range interfaces {
		for _, address := range networkInterface.AddressInfo {
			if address.Family == "inet" && address.Local == selected {
				return selected, nil
			}
		}
	}
	return "", fmt.Errorf("node IP %s is not assigned to interface %s", selected, route.Device)
}

func (a *App) sanitiseK3sConfig(ctx context.Context, source, endpoint, nodeIP string) (string, error) {
	endpointJSON, _ := json.Marshal(endpoint)
	nodeIPJSON, _ := json.Marshal(nodeIP)
	filter := fmt.Sprintf(`.server = %s | ."token-file" = %q | ."node-ip" = %s | ."kube-apiserver-arg" = ((."kube-apiserver-arg" // []) | map(select(test("^anonymous-auth(=true)?$") | not))) | del(."node-external-ip", ."node-name", ."node-label", ."node-taint", ."advertise-address", ."bind-address", ."flannel-iface", .token, ."write-kubeconfig-mode", ."cluster-init", ."cluster-reset", ."cluster-reset-restore-path")`, endpointJSON, targetTokenPath, nodeIPJSON)
	config, err := a.exec.output(ctx, a.paths.repo, strings.NewReader(source), "yq", "eval", filter, "-")
	if err != nil {
		return "", fmt.Errorf("could not sanitise source K3s config")
	}
	unsafeAnonymousAuth := regexp.MustCompile(`(?im)anonymous-auth\s*(?:=|:)\s*true`)
	unsafeKubeconfigMode := regexp.MustCompile(`(?im)write-kubeconfig-mode\s*:\s*["']?0?644`)
	if unsafeAnonymousAuth.MatchString(config) || unsafeKubeconfigMode.MatchString(config) {
		return "", fmt.Errorf("source K3s config contains unsafe authentication or kubeconfig settings")
	}
	return config + "\n", nil
}

func (a *App) stageTargetEnrolFiles(ctx context.Context, host, config, token string) error {
	if err := a.prepareTargetEnrolStage(ctx, host); err != nil {
		return err
	}
	if err := a.installTargetConfig(ctx, host, config, enrolStagePath+"/config.yaml"); err != nil {
		return a.clearTargetEnrolStageAfterError(ctx, host, err)
	}
	if err := a.installTargetToken(ctx, host, token, enrolStagePath+"/cluster-token"); err != nil {
		return a.clearTargetEnrolStageAfterError(ctx, host, err)
	}
	if err := a.promoteTargetEnrolStage(ctx, host); err != nil {
		return a.clearTargetEnrolStageAfterError(ctx, host, err)
	}
	return nil
}

func (a *App) prepareTargetEnrolStage(ctx context.Context, host string) error {
	return a.exec.runToStderr(ctx, a.paths.repo, nil, "ssh", "pi@"+host, "sudo install -d -m 0700 "+enrolStagePath+" && sudo rm -f "+enrolStagePath+"/config.yaml "+enrolStagePath+"/cluster-token")
}

func (a *App) installTargetConfig(ctx context.Context, host, config, destination string) error {
	return a.exec.runToStderr(ctx, a.paths.repo, strings.NewReader(config), "ssh", "pi@"+host, "sudo install -m 0600 /dev/stdin "+destination)
}

func (a *App) installTargetToken(ctx context.Context, host, token, destination string) error {
	return a.exec.runSecret(ctx, a.paths.repo, strings.NewReader(token+"\n"), "ssh", "pi@"+host, "sudo install -m 0600 /dev/stdin "+destination)
}

func (a *App) promoteTargetEnrolStage(ctx context.Context, host string) error {
	command := "sudo sh -c 'if mv " + enrolStagePath + "/config.yaml /etc/rancher/k3s/config.yaml && mv " + enrolStagePath + "/cluster-token /etc/rancher/k3s/cluster-token && rmdir " + enrolStagePath + "; then exit 0; fi; rm -f /etc/rancher/k3s/config.yaml /etc/rancher/k3s/cluster-token; rm -rf " + enrolStagePath + "; exit 1'"
	return a.exec.runToStderr(ctx, a.paths.repo, nil, "ssh", "pi@"+host, command)
}

func (a *App) clearTargetEnrolStageAfterError(ctx context.Context, host string, operationErr error) error {
	if cleanupErr := a.exec.runToStderr(ctx, a.paths.repo, nil, "ssh", "pi@"+host, "sudo rm -rf "+enrolStagePath); cleanupErr != nil {
		return fmt.Errorf("%w; clear enrolment staging: %v", operationErr, cleanupErr)
	}
	return operationErr
}

func (a *App) removeRetiredClusterState(ctx context.Context, host string) error {
	return a.exec.runToStderr(ctx, a.paths.repo, nil, "ssh", "pi@"+host, "sudo rm -rf "+strings.Join(retiredClusterStatePaths, " "))
}

func (a *App) waitForEnrolledNode(ctx context.Context, name, host, token string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	lastState := "node not found"
	for {
		node, err := a.existingNode(ctx, name)
		if err != nil {
			lastState = redactLifecycleError(err, token).Error()
		} else if node != nil {
			lastState = nodeReadinessState(*node)
			if nodeReady(*node) && nodeControlPlane(*node) && nodeEtcd(*node) {
				return nil
			}
		}
		if !time.Now().Before(deadline) {
			break
		}
		time.Sleep(minDuration(5*time.Second, time.Until(deadline)))
	}
	logs, err := a.sshOutputRedacted(ctx, host, "timeout 15s sudo -n journalctl -u k3s.service --no-pager -n 200 --since '-10 minutes'", func(value string) string { return redactSecret(value, token) })
	if err != nil {
		logs = "<unavailable>"
	}
	logs = redactSecret(logs, token)
	if len(logs) > 8000 {
		logs = logs[len(logs)-8000:]
	}
	return fmt.Errorf("node %s did not become Ready with control-plane and etcd roles within %s; last state: %s; bounded k3s logs:\n%s", name, timeout, redactSecret(lastState, token), logs)
}

func (a *App) kubectlOutput(ctx context.Context, args ...string) (string, error) {
	return a.exec.output(ctx, a.paths.repo, nil, "kubectl", args...)
}

func (a *App) sshOutput(ctx context.Context, host, command string) (string, error) {
	return a.exec.output(ctx, a.paths.repo, nil, "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "pi@"+host, command)
}

func (a *App) sshOutputRedacted(ctx context.Context, host, command string, redact func(string) string) (string, error) {
	output, err := a.sshOutput(ctx, host, command)
	if err != nil {
		return "", fmt.Errorf("ssh failed: %s", redact(err.Error()))
	}
	return redact(output), nil
}

func (a *App) requireConfirmation(expected, action string) error {
	fmt.Fprintf(a.exec.stderr, "Type %s %s: ", expected, action)
	reader := bufio.NewReader(a.exec.stdin)
	answer, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		return fmt.Errorf("read confirmation: %w", err)
	}
	if strings.TrimSpace(answer) != expected {
		return fmt.Errorf("confirmation did not match")
	}
	return nil
}

func nodeReady(node kubernetesNode) bool {
	for _, condition := range node.Status.Conditions {
		if condition.Type == "Ready" && condition.Status == "True" {
			return true
		}
	}
	return false
}

func nodeControlPlane(node kubernetesNode) bool {
	_, controlPlane := node.Metadata.Labels["node-role.kubernetes.io/control-plane"]
	_, master := node.Metadata.Labels["node-role.kubernetes.io/master"]
	return controlPlane || master
}

func nodeEtcd(node kubernetesNode) bool {
	_, etcd := node.Metadata.Labels["node-role.kubernetes.io/etcd"]
	return etcd
}

func nodeAddress(node kubernetesNode) (string, error) {
	for _, kind := range []string{"InternalIP", "ExternalIP", "Hostname"} {
		for _, address := range node.Status.Addresses {
			if address.Type == kind && address.Address != "" {
				return address.Address, nil
			}
		}
	}
	return "", fmt.Errorf("node %s has no SSH address", node.Metadata.Name)
}

func nodeState(node kubernetesNode) map[string]any {
	return map[string]any{"name": node.Metadata.Name, "uid": node.Metadata.UID, "ready": nodeReady(node), "unschedulable": node.Spec.Unschedulable}
}

func nodeReadinessState(node kubernetesNode) string {
	state, _ := json.Marshal(map[string]any{"ready": nodeReady(node), "control_plane": nodeControlPlane(node), "etcd": nodeEtcd(node)})
	return string(state)
}

func isIPv4(value string) bool {
	parsed := net.ParseIP(value)
	return parsed != nil && parsed.To4() != nil && parsed.String() == value
}

func redactSecret(value, secret string) string {
	if secret == "" {
		return value
	}
	return strings.ReplaceAll(value, secret, "<redacted>")
}

func redactLifecycleError(err error, token string) error {
	return fmt.Errorf("%s", redactSecret(err.Error(), token))
}

func minDuration(first, second time.Duration) time.Duration {
	if first < second {
		return first
	}
	return second
}
