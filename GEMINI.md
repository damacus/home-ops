# Gemini CLI Context & Maintenance Guide

This document provides context and common maintenance actions for the `home-ops` repository. It is designed to help the Gemini CLI understand the repository structure and available automation tools.

## Project Overview

This repository manages home infrastructure with Kubernetes and Flux. Taskfile
drives cluster and repository maintenance. Mise pins the toolchain and exposes
the golden-image and node lifecycle under `mise run provisioning:*`.

## Common Maintenance Actions

### 1. Flux & Kubernetes Operations

* **Reconcile Flux**: Force Flux to pull the latest changes from the git repository.

    ```bash
    task flux:reconcile
    ```

* **Apply Flux Kustomization**: Manually build and apply a specific Flux Kustomization (useful for testing changes without waiting for git sync).

    ```bash
    task flux:apply path=apps/my-app
    ```

  * `path`: Path under `kubernetes/apps` containing the `ks.yaml`.
  * `ns`: Namespace (default: `flux-system`).

* **Gather Cluster Resources**: List common resources (Nodes, GitRepositories, Kustomizations, HelmReleases, etc.) for debugging.

    ```bash
    task k8s:resources
    ```

* **Validate Manifests**: Run `yayamlls` against the Kubernetes manifests and rendered Flux output.

    ```bash
    task k8s:yayamlls
    ```

### 2. Repository Management

* **Configure Repository**: Configure the repository from bootstrap variables (generates secrets, validates config).

    ```bash
    task configure
    ```

* **Clean Up**: Remove files no longer needed after cluster bootstrap.

    ```bash
    task repo:clean
    ```

* **Reset Configuration**: Reset templated configuration files to their default state.

    ```bash
    task repo:reset
    ```

* **Force Reset**: Reset the repository back to HEAD, cleaning all changes.

    ```bash
    task repo:force-reset
    ```

### 3. Radxa Provisioning

* **Check prerequisites**: Validate Docker Desktop and available disk space.

    ```bash
    mise run provisioning:docker:doctor
    ```

* **Build and verify an image**: Build the hardened, unjoined golden image,
  then verify its artifact set before use.

    ```bash
    mise run provisioning:build
    mise run provisioning:verify provisioning/artifacts/<release-id>.img.xz
    ```

* **Enrol a host**: Join a flashed host to an existing healthy cluster over
  SSH. This is an explicit operation; the image never contains a token or
  cluster address.

    ```bash
    mise run provisioning:enrol <host>
    ```

* **Inspect or retire nodes**:

    ```bash
    mise run provisioning:status
    mise run provisioning:retire <node> <host>
    ```

## Common Workflows

### Deploying a New Application

1. Create the application manifests in `kubernetes/apps/<category>/<app-name>`.
2. Create a `ks.yaml` (Flux Kustomization) for the app.
3. Validate the manifests:

    ```bash
    task k8s:yayamlls
    ```

4. Apply the changes manually to test (optional):

    ```bash
    task flux:apply path=<category>/<app-name>
    ```

5. Commit and push changes.
6. Reconcile Flux to sync immediately:

    ```bash
    task flux:reconcile
    ```

### Troubleshooting Flux Issues

1. Check the status of Flux resources:

    ```bash
    task k8s:resources
    ```

2. If a HelmRelease is stuck, try reconciling the cluster kustomization:

    ```bash
    task flux:reconcile
    ```

3. View logs for a specific pod (standard kubectl):

    ```bash
    kubectl logs -n <namespace> <pod-name>
    ```

## Directory Structure Key

* `kubernetes/`: Kubernetes manifests and Flux configuration.
* `.taskfiles/`: Definitions for the `task` CLI.
* `.mise/tasks/provisioning/`: Mise provisioning entry points.
* `provisioning/`: Armbian image, artifact, and SSH node lifecycle implementation.
* `scripts/`: Helper scripts used by tasks.
