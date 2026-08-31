package clusterhealth

import (
	"context"
	"fmt"
	"strings"
)

func (c *Checker) Nodes(ctx context.Context) Result {
	nodes, err := kubectlJSON[objectList[node]](ctx, c, "get", "nodes")
	if err != nil {
		return c.failedResult("nodes", err)
	}
	bad := []string{}
	for _, item := range nodes.Items {
		ready := false
		for _, current := range item.Status.Conditions {
			if current.Type == "Ready" && current.Status == "True" {
				ready = true
				break
			}
		}
		if !ready {
			bad = append(bad, item.Metadata.Name)
		}
	}
	return NewResult(
		"nodes",
		len(bad) > 0,
		"all nodes Ready",
		fmt.Sprintf("%d nodes not Ready", len(bad)),
		bad,
	)
}

func (c *Checker) KubeVIP(ctx context.Context) Result {
	pods, err := kubectlJSON[objectList[pod]](
		ctx,
		c,
		"get", "pods", "-n", "kube-system", "-l", "app.kubernetes.io/name=kube-vip",
	)
	if err != nil {
		return c.failedResult("kube-vip", err)
	}
	bad := []string{}
	for _, item := range pods.Items {
		ready := item.Status.Phase == "Running"
		for _, container := range item.Status.ContainerStatuses {
			ready = ready && container.Ready
		}
		if !ready {
			bad = append(bad, item.Metadata.Name)
		}
	}
	failed := len(pods.Items) == 0 || len(bad) > 0
	return NewResult(
		"kube-vip",
		failed,
		fmt.Sprintf("%d kube-vip pods ready", len(pods.Items)),
		"kube-vip pod readiness failed",
		bad,
	)
}

func (c *Checker) Cilium(ctx context.Context) Result {
	output := c.Runner.Run(
		ctx,
		"kubectl",
		"exec", "-n", "kube-system", "ds/cilium", "--", "cilium-dbg", "status", "--brief",
	)
	detail := strings.TrimSpace(strings.Join(nonEmpty(output.Stdout, output.Stderr), "\n"))
	details := []string{}
	if detail != "" {
		details = append(details, detail)
	}
	failed := output.ExitCode != 0 || detail != "OK"
	return NewResult("cilium", failed, "Cilium status OK", "Cilium status check failed", details)
}

func (c *Checker) Pods(ctx context.Context) Result {
	pods, err := kubectlJSON[objectList[pod]](ctx, c, "get", "pods", "-A")
	if err != nil {
		return c.failedResult("pods", err)
	}
	bad := []string{}
	for _, item := range pods.Items {
		if item.Status.Phase == "Succeeded" {
			continue
		}
		waiting := []string{}
		readyCount := 0
		for _, container := range item.Status.ContainerStatuses {
			if container.Ready {
				readyCount++
			}
			if reason := container.State.Waiting.Reason; reason != "" {
				waiting = append(waiting, reason)
			}
		}
		total := len(item.Status.ContainerStatuses)
		if item.Status.Phase == "Running" && len(waiting) == 0 && (total == 0 || readyCount == total) {
			continue
		}
		reason := strings.Join(waiting, ",")
		if reason == "" {
			reason = item.Status.Phase
		}
		if reason == "" {
			reason = fmt.Sprintf("%d/%d ready", readyCount, total)
		}
		bad = append(bad, fmt.Sprintf("%s/%s: %s", item.Metadata.Namespace, item.Metadata.Name, reason))
	}
	failureCount := len(bad)
	if failureCount > 30 {
		bad = bad[:30]
	}
	return NewResult(
		"pods",
		failureCount > 0,
		"all active pods ready",
		fmt.Sprintf("%d active pods not ready", failureCount),
		bad,
	)
}

func (c *Checker) Deployments(ctx context.Context) Result {
	deployments, err := kubectlJSON[objectList[deployment]](ctx, c, "get", "deploy", "-A")
	if err != nil {
		return c.failedResult("deployments", err)
	}
	bad := []string{}
	for _, item := range deployments.Items {
		desired := 1
		if item.Spec.Replicas != nil {
			desired = *item.Spec.Replicas
		}
		if item.Status.ReadyReplicas != desired || item.Status.AvailableReplicas != desired {
			bad = append(
				bad,
				fmt.Sprintf("%s/%s: %d/%d ready", item.Metadata.Namespace, item.Metadata.Name, item.Status.ReadyReplicas, desired),
			)
		}
	}
	return NewResult(
		"deployments",
		len(bad) > 0,
		"all deployments available",
		fmt.Sprintf("%d deployments unavailable", len(bad)),
		bad,
	)
}

func (c *Checker) ServiceAccounts(ctx context.Context) Result {
	pods, err := kubectlJSON[objectList[pod]](ctx, c, "get", "pods", "-A")
	if err != nil {
		return c.failedResult("service-accounts", err)
	}
	accounts, err := kubectlJSON[objectList[serviceAccount]](ctx, c, "get", "serviceaccount", "-A")
	if err != nil {
		return c.failedResult("service-accounts", err)
	}
	available := map[string]struct{}{}
	for _, account := range accounts.Items {
		available[account.Metadata.Namespace+"/"+account.Metadata.Name] = struct{}{}
	}
	missing := []string{}
	for _, item := range pods.Items {
		if item.Status.Phase == "Succeeded" || item.Status.Phase == "Failed" {
			continue
		}
		account := item.Spec.ServiceAccountName
		if account == "" {
			account = "default"
		}
		if _, ok := available[item.Metadata.Namespace+"/"+account]; !ok {
			missing = append(
				missing,
				fmt.Sprintf("%s/%s: ServiceAccount %s is missing", item.Metadata.Namespace, item.Metadata.Name, account),
			)
		}
	}
	failSummary := fmt.Sprintf("%d active pods have a missing ServiceAccount", len(missing))
	if len(missing) == 1 {
		failSummary = "1 active pod has a missing ServiceAccount"
	}
	return NewResult(
		"service-accounts",
		len(missing) > 0,
		"all active pods have ServiceAccounts",
		failSummary,
		missing,
	)
}

func nonEmpty(values ...string) []string {
	nonEmptyValues := []string{}
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			nonEmptyValues = append(nonEmptyValues, strings.TrimSpace(value))
		}
	}
	return nonEmptyValues
}
