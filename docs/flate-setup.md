# Flate Local Testing Setup

This repository uses [flate](https://github.com/home-operations/flate) to render and validate Flux configurations locally before pushing to GitHub. The local task names match the GitHub Actions workflow.

## Components

### Mise Commands

- `mise run flux:flate-test`: validate all Kustomizations and HelmReleases render successfully.
- `mise run flux:flate-build`: build rendered Flux resources locally.
- `mise run flux:flate-diff`: diff rendered resources against a baseline checkout or supplied baseline path.

### Validation

`yayamlls` performs schema validation over the raw and rendered Kubernetes manifests:

```bash
mise run kubernetes:yayamlls
```

## Usage

Run the full flate test:

```bash
mise run flux:flate-test
```

Build a specific path:

```bash
mise run flux:flate-build path=./kubernetes/apps/network
```

Diff against `origin/main`:

```bash
mise run flux:flate-diff
```

Diff against an existing baseline checkout:

```bash
mise run flux:flate-diff path_orig=./default/kubernetes
```

## What It Tests

- Kustomization rendering.
- HelmRelease rendering.
- Resource syntax.
- Dependency resolution.
- CRD availability for configured API versions.

## GitHub Actions

The workflow in `.github/workflows/flux.yaml` installs `home-operations/flate/action` and invokes the native Mise tasks.

## Missing CRD Errors

If flate reports that an API version is unavailable, update the API version list in `.mise/tasks/flux/flate-test`, `.mise/tasks/flux/flate-build`, and `.mise/tasks/flux/flate-diff`. CI uses these same native Mise tasks from `.github/workflows/flux.yaml`.
