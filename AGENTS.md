# AGENTS.md - Home-Ops Project Specification

## Project Overview

This repository, `home-ops`, is a production-grade home infrastructure management system. It leverages **Infrastructure as Code (IaC)** principles to manage a multi-node Kubernetes cluster, physical host provisioning, and a wide array of self-hosted services.

### Core Technology Stack

- **Kubernetes**: Orchestration layer (k3s distribution).
- **Flux CD (Flux Operator)**: GitOps tool for continuous delivery and cluster state management.
- **Mise**: Pinned tooling and the provisioning lifecycle for golden images and nodes.
- **Taskfile (go-task)**: The automation harness for Kubernetes and repository operations.
- **Cilium**: CNI with Gateway API implementation for ingress/egress.
- **Armbian and cloud-init**: Reproducible, hardened Radxa golden images.
- **Mondoo/cnspec**: Compliance and validation testing.

## Directory Structure

- `kubernetes/`: Flux-managed Kubernetes manifests.
  - `apps/`: Application-specific manifests, categorized by namespace or purpose.
  - `flux/`: Core Flux configuration and Kustomizations.
- `provisioning/`: Golden-image build, verification, flashing, and explicit SSH node lifecycle logic.
- `.mise/tasks/provisioning/`: Mise entry points for image and node operations.
- `.taskfiles/`: Modular Taskfile definitions.
- `scripts/`: Support scripts for automation.

## Development Workflow & Rules

1. **Verification**: Exercise deployment behaviour on the existing Docker Desktop Kubernetes cluster.
   - Check availability with `kubectl --context docker-desktop get nodes --request-timeout=10s`.
   - Use an explicit `--context docker-desktop`, a dedicated namespace and synthetic data and credentials. Never switch the global context or use production as a development fallback.
   - Use the existing pinned Helm chart and supported values. Reuse render, schema and Mondoo checks before install or upgrade checks.
   - Do not add or run Python tests. Do not replace removed tests with another custom framework or assertions that repeat YAML values.
   - Verify the relevant behaviour with real tools: startup, restart, persistence, authentication and allowed and denied access. Keep native Go, JavaScript, Ruby and alert-rule tests only where they exercise executable behaviour or a significant independent safety condition.
   - Record the commands, results and gaps. Docker Desktop does not prove production Cilium policies, Rockchip devices or NAS behaviour. Remove only local verification resources you created.
2. **Conventional Commits**: All commits must follow the `feat:`, `fix:`, `refactor:`, `test:` format.
3. **Small, Atomic Changes**: Avoid monolithic PRs. Each change should be verifiable.
4. **Repository Automation**: Prefer `task <command>` for cluster operations and `mise run provisioning:<command>` for host provisioning.
5. **Strong Typing**: Use type hints in all languages (Python, Go, etc.) where supported.

## What We Are Building

We are building a highly resilient, automated, and observable home infrastructure. Key focus areas include:

- **Migration to Flux Operator**: Ensuring discovery of resources across all paths.
- **Gateway API Adoption**: Moving from legacy ingress to Cilium Gateway API.
- **Automated Provisioning**: Full cycle from a verified golden image to an explicitly enrolled Radxa node.
- **Security & Identity**: Implementing robust authentication and secrets management.
- **Observability**: Comprehensive monitoring with Prometheus, Grafana, and Loki.

## Agent Instructions

When working in this repository:

- Treat the current user request as the scope of work. Existing production services are not a backlog of features to implement.
- Record scope, validation and outstanding work in the PR description. Use application READMEs for operating procedures; do not recreate generated task ledgers or session progress logs.
- Maintain consistency with existing architecture and naming conventions.
- Before changing a Helm deployment, identify its existing chart, pinned version, values and rendered resources. Use supported chart configuration; replacing or wrapping the chart requires owner agreement.
