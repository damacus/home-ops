# AGENTS.md - Home-Ops Project Specification

## Project Overview

This repository, `home-ops`, is a production-grade home infrastructure management system. It leverages **Infrastructure as Code (IaC)** principles to manage a multi-node Kubernetes cluster, physical host provisioning, and a wide array of self-hosted services.

### Core Technology Stack

- **Kubernetes**: Orchestration layer (k3s distribution).
- **Flux CD (Flux Operator)**: GitOps tool for continuous delivery and cluster state management.
- **Ansible**: Physical host provisioning and configuration management.
- **Taskfile (go-task)**: The primary automation harness and entry point for all operations.
- **Cilium**: CNI with Gateway API implementation for ingress/egress.
- **Cloud-init**: Initial node bootstrapping.
- **InSpec**: Compliance and validation testing.

## Directory Structure

- `kubernetes/`: Flux-managed Kubernetes manifests.
  - `apps/`: Application-specific manifests, categorized by namespace or purpose.
  - `flux/`: Core Flux configuration and Kustomizations.
- `ansible/`: Playbooks and inventory for host management.
- `provisioning/`: hardware-level provisioning logic, cloud-init templates, and VM validation loops.
- `.taskfiles/`: Modular Taskfile definitions.
- `scripts/`: Support scripts for automation.
- `.tasks/`: **NEW** Segregated task lists for AI agents to track progress.

## Development Workflow & Rules

1. **Test-Driven Development (TDD)**: Every production change must be driven by a failing test.
2. **Conventional Commits**: All commits must follow the `feat:`, `fix:`, `refactor:`, `test:` format.
3. **Small, Atomic Changes**: Avoid monolithic PRs. Each change should be verifiable.
4. **Task-Based Execution**: Always prefer `task <command>` over direct script execution.
5. **Strong Typing**: Use type hints in all languages (Python, Go, etc.) where supported.

## What We Are Building

We are building a highly resilient, automated, and observable home infrastructure. Key focus areas include:

- **Migration to Flux Operator**: Ensuring discovery of resources across all paths.
- **Gateway API Adoption**: Moving from legacy ingress to Cilium Gateway API.
- **Automated Provisioning**: Full cycle from bare metal/VM to joined Kubernetes node.
- **Security & Identity**: Implementing robust authentication and secrets management.
- **Observability**: Comprehensive monitoring with Prometheus, Grafana, and Loki.

## Agent Instructions

When working in this repository:

- Consult `.tasks/*.json` for your current objectives.
- Update the relevant task list by setting `"passes": true` only after verifying functionality with tests.
- Reference `GEMINI.md` for specific maintenance commands and troubleshooting.
- Maintain consistency with existing architecture and naming conventions.
