package clusterhealth

import (
	"context"
	"fmt"
)

func (c *Checker) readinessFailures(resources []readinessResource, kind string, ignoreSuspended bool) []string {
	failures := []string{}
	for _, resource := range resources {
		if ignoreSuspended && resource.Spec.Suspend {
			continue
		}
		var ready *condition
		var reconciling *condition
		for index := range resource.Status.Conditions {
			current := &resource.Status.Conditions[index]
			if current.Type == "Ready" {
				ready = current
			}
			if current.Type == "Reconciling" && current.Status == "True" {
				reconciling = current
			}
		}
		if ready != nil && ready.Status == "True" {
			continue
		}
		transition := ""
		if reconciling != nil {
			transition = reconciling.LastTransitionTime
		} else if ready != nil && ready.Reason == "Progressing" {
			transition = ready.LastTransitionTime
		}
		if transition != "" {
			age, err := c.age(transition)
			if err == nil && age <= reconciliationGrace {
				continue
			}
		}
		name := resource.Metadata.Namespace + "/" + resource.Metadata.Name
		if ready == nil {
			failures = append(failures, fmt.Sprintf("%s %s: Ready condition missing", kind, name))
			continue
		}
		reason := ready.Reason
		if reason == "" {
			reason = "Ready=" + ready.Status
		}
		if ready.Message != "" {
			reason += ": " + ready.Message
		}
		failures = append(failures, fmt.Sprintf("%s %s: %s", kind, name, reason))
	}
	return failures
}

func (c *Checker) GitOps(ctx context.Context) Result {
	queries := []struct {
		kind     string
		resource string
	}{
		{kind: "GitRepository", resource: "gitrepository"},
		{kind: "Kustomization", resource: "kustomization"},
		{kind: "HelmRelease", resource: "helmrelease"},
	}
	failures := []string{}
	for _, query := range queries {
		resources, err := kubectlJSON[objectList[readinessResource]](ctx, c, "get", query.resource, "-A")
		if err != nil {
			return c.failedResult("gitops", err)
		}
		failures = append(failures, c.readinessFailures(resources.Items, query.kind, true)...)
	}
	return NewResult(
		"gitops",
		len(failures) > 0,
		"all unsuspended Flux resources Ready",
		fmt.Sprintf("%d Flux resources not Ready", len(failures)),
		failures,
	)
}

func (c *Checker) ExternalSecrets(ctx context.Context) Result {
	resources, err := kubectlJSON[objectList[readinessResource]](ctx, c, "get", "externalsecret", "-A")
	if err != nil {
		return c.failedResult("external-secrets", err)
	}
	failures := c.readinessFailures(resources.Items, "ExternalSecret", false)
	failSummary := fmt.Sprintf("%d ExternalSecrets not Ready", len(failures))
	if len(failures) == 1 {
		failSummary = "1 ExternalSecret not Ready"
	}
	return NewResult(
		"external-secrets",
		len(failures) > 0,
		"all ExternalSecrets Ready",
		failSummary,
		failures,
	)
}
