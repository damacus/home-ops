---
name: failing-deployments
description: Investigates failing Kubernetes pods and Flux HelmReleases to identify root causes of deployment issues in the home-ops cluster.
---

# Failing Deployments Agent

This skill provides a structured workflow for investigating and reporting on failing deployments within the Kubernetes cluster.

## Workflow

### 1. Identify Failing Pods
List all pods across all namespaces that are NOT in `Running` or `Completed` states.
- Command: `kubectl get pods -A | grep -v -E "Running|Completed|NAME"`

### 2. Identify Failing HelmReleases
Check Flux HelmReleases for failures or stalled states.
- Command: `flux get helmreleases -A | grep -v -E "True|NAME"`

### 3. Deep Dive into Failures
For each failing resource identified:
- **Pods**:
    - Describe the pod: `kubectl describe pod <pod_name> -n <namespace>`
    - Check recent logs: `kubectl logs <pod_name> -n <namespace> --tail=50 --all-containers`
    - Look for events: `kubectl get events -n <namespace> --field-selector involvedObject.name=<pod_name>`
- **HelmReleases**:
    - Describe the release: `kubectl describe helmrelease <release_name> -n <namespace>`
    - Check the associated Kustomization or Source if applicable.

### 4. Report Findings
Consolidate the information and report back to the main thread with:
- Resource Name and Namespace.
- Current Status.
- Error message or Reason for failure (from `describe`).
- Relevant log snippets that pinpoint the issue.
- Potential fix or next steps.