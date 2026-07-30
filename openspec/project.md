# Home-Ops OpenSpec Context

## Purpose

This repository defines the desired state and recovery path for the home
infrastructure. Specifications cover behavior that must survive cluster or
service loss, not only the Kubernetes resources required during normal
operation.

## Architecture

- Flux reconciles Kubernetes resources from Git.
- Ansible and cloud-init provision hosts and bootstrap the cluster.
- External Secrets projects secret material from its authoritative secret
  store into Kubernetes.
- Application databases and other mutable service data require backup and
  restore coverage.
- External service APIs require a controller or provider capable of
  continuously reconciling their desired state.

## Specification Rules

- Describe observable behavior and recovery outcomes in capability specs.
- Keep implementation decisions and trade-offs in change design documents.
- Do not place credentials, private keys, personal data, or Terraform state in
  Git.
- Distinguish declarative configuration, secret material, generated state,
  mutable application data, and unavoidable bootstrap operations.
- Every manually configured setting must have a recorded authority and a tested
  recovery path.

## Verification

Changes must use repository-native validation through `task` where available.
Infrastructure changes require static validation, a non-destructive plan, drift
checks, and a documented recovery test before migration is complete.
