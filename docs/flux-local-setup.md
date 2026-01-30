# flux-local Local Testing Setup

This repository uses [flux-local](https://github.com/allenporter/flux-local) to validate Flux configurations locally before pushing to GitHub. This matches the behavior of the GitHub Actions workflow.

## Overview

The setup uses the official pre-built Docker image (`ghcr.io/allenporter/flux-local:v8.1.0`) to ensure consistent behavior between local development and CI/CD.

## Components

### 1. Docker Compose Configuration

- **File**: `docker-compose.flux-local.yml`
- **Image**: `ghcr.io/allenporter/flux-local:v8.1.0`
- Mounts the repository as read-only at `/workspace`

### 2. Wrapper Script

- **File**: `scripts/flux-local-container.sh`
- Simplifies running flux-local commands in the container
- Passes all arguments through to the flux-local CLI

### 3. Task Commands

- **`task flux:local-test`**: Run flux-local test (validates all Kustomizations and HelmReleases)
- **`task flux:local-build`**: Build all Flux resources locally

### 4. Pre-commit Hook

- Automatically runs `flux-local test` on commits that modify files in `kubernetes/`
- Configured in `.pre-commit-config.yaml`

## Usage

### Manual Testing

Run flux-local test:

```bash
task flux:local-test
```

Run with verbose output:

```bash
task flux:local-test verbose=true
```

Test a specific path:

```bash
task flux:local-test path=./kubernetes/apps/network
```

### Direct Docker Compose

You can also run flux-local directly:

```bash
docker compose -f docker-compose.flux-local.yml run --rm flux-local test --enable-helm --path ./kubernetes
```

### Pre-commit Hook

The pre-commit hook runs automatically on commits. To run it manually:

```bash
pre-commit run flux-local-test --all-files
```

To skip the hook on a specific commit:

```bash
git commit --no-verify
```

## What It Tests

- **Kustomization validation**: Ensures all Kustomizations can be built successfully
- **HelmRelease validation**: Templates all HelmReleases and validates outputs
- **Resource syntax**: Validates YAML syntax and Kubernetes resource schemas
- **Dependencies**: Checks that all dependencies are resolvable
- **CRD availability**: Simulates availability of Prometheus Operator CRDs (ServiceMonitor, PodMonitor, PrometheusRule) and PodDisruptionBudget

## Comparison with GitHub Action

This local setup mirrors the GitHub Action workflow defined in `.github/workflows/flux.yaml`:

- Uses the same flux-local version
- Runs the same test command with `--enable-helm`
- Validates the same path (`./kubernetes`)

## Troubleshooting

### Image Pull Issues

If you encounter image pull errors:

```bash
docker compose -f docker-compose.flux-local.yml pull
```

### Permission Issues

The container runs with your user's permissions. Ensure the repository is readable.

### Test Failures

Review the output for specific errors. Common issues:

- Invalid YAML syntax
- Missing dependencies
- Incorrect Helm values
- Invalid Kubernetes resource schemas

### Missing CRD Errors

If you see errors like `You have to deploy monitoring.coreos.com/v1 first`, the `--api-versions` flag needs to include the missing CRD. The current configuration includes:

- `policy/v1/PodDisruptionBudget`
- `monitoring.coreos.com/v1/ServiceMonitor`
- `monitoring.coreos.com/v1/PodMonitor`
- `monitoring.coreos.com/v1/PrometheusRule`

Add additional API versions to the task command or pre-commit hook as needed.
