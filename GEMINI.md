# Gemini CLI Context & Maintenance Guide

This document provides context and common maintenance actions for the `home-ops` repository. It is designed to help the Gemini CLI understand the repository structure and available automation tools.

## Project Overview

This repository manages home infrastructure with Kubernetes and Flux. Mise
pins the toolchain and provides the repository's automation interface.

## Common Maintenance Actions

### 1. Flux & Kubernetes Operations

* **Reconcile Flux**: Force Flux to pull the latest changes from the git repository.

    ```bash
    mise run flux:reconcile
    ```

* **Apply Flux Kustomization**: Manually build and apply a specific Flux Kustomization (useful for testing changes without waiting for git sync).

    ```bash
    mise run flux:apply apps/my-app
    ```

  * `path`: Path under `kubernetes/apps` containing the `ks.yaml`.
  * `ns`: Namespace (default: `flux-system`).

* **Gather Cluster Resources**: List common resources (Nodes, GitRepositories, Kustomizations, HelmReleases, etc.) for debugging.

    ```bash
    mise run kubernetes:resources
    ```

* **Validate Manifests**: Run `yayamlls` against the Kubernetes manifests and rendered Flux output.

    ```bash
    mise run kubernetes:yayamlls
    ```

### 2. Repository Management

* **Configure Repository**: Configure the repository from bootstrap variables (generates secrets, validates config).

    ```bash
    mise run configure
    ```

* **Clean Up**: Remove files no longer needed after cluster bootstrap.

    ```bash
    mise run repository:clean
    ```

* **Reset Configuration**: Reset templated configuration files to their default state.

    ```bash
    mise run repository:reset
    ```

* **Force Reset**: Reset the repository back to HEAD, cleaning all changes.

    ```bash
    mise run repository:force-reset
    ```

### 3. Radxa Provisioning

Provisioning keeps the public operator interface in Mise. The Go command in
`cmd/provisioning` and `internal/provisioning` owns build planning, artifact
validation, image verification, guarded flashing, and SSH lifecycle safety.
The file tasks under `.mise/tasks/provisioning/` own composition and the
straightforward Bash operations such as Docker reporting, scoped cleanup,
staging, and release invocation. Armbian `compile.sh` remains the final build
boundary. Do not add Python or duplicate lifecycle logic in Mise entry points.

* **Check prerequisites**: Validate Docker Desktop and available disk space.

    ```bash
    mise run provisioning:docker:doctor
    ```

* **Build and verify an image**: Build the hardened, unjoined golden image,
  then verify its artifact set and boot-critical NVMe support before use.

    ```bash
    mise run provisioning:build
    mise run provisioning:verify provisioning/artifacts/<release-id>.img.xz
    ```

  Verification must find the executable
  `etc/initramfs-tools/scripts/local-premount/nvme-rescan` in the rootfs and
  the same `scripts/local-premount/nvme-rescan` entry in a generated initramfs.
  The source overlay alone is not evidence that a boot image has the hook.

* **Enrol a host**: Join a flashed host to an existing healthy cluster over
  SSH. This is an explicit operation; the image never contains a token or
  cluster address. Enrolment derives the target IPv4 address from its route
  to the Kubernetes API, validates that the address is assigned to that
  interface, and writes `node-ip` into the sanitised K3s config. Use
  `--node-ip <IPv4>` when an explicit assigned address is required. The
  source node's token is copied over SSH only after all dry-run, identity, and
  replacement gates pass, and is never printed.

    ```bash
    mise run provisioning:enrol <host> --node-ip <IPv4>
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
    mise run kubernetes:yayamlls
    ```

4. Apply the changes manually to test (optional):

    ```bash
    mise run flux:apply <category>/<app-name>
    ```

5. Commit and push changes.
6. Reconcile Flux to sync immediately:

    ```bash
    mise run flux:reconcile
    ```

### Troubleshooting Flux Issues

1. Check the status of Flux resources:

    ```bash
    mise run kubernetes:resources
    ```

2. If a HelmRelease is stuck, try reconciling the cluster kustomization:

    ```bash
    mise run flux:reconcile
    ```

3. View logs for a specific pod (standard kubectl):

    ```bash
    kubectl logs -n <namespace> <pod-name>
    ```

## Directory Structure Key

* `kubernetes/`: Kubernetes manifests and Flux configuration.
* `.mise/tasks/`: Repository, cluster, and provisioning automation.
* `provisioning/`: Armbian image, artifact, and SSH node lifecycle implementation.
* `scripts/`: Helper scripts used by tasks.
