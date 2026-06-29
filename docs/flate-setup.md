# Flate Local Testing Setup

This repository uses [flate](https://github.com/home-operations/flate) to render and validate Flux configurations locally before pushing to GitHub. The local task names match the GitHub Actions workflow.

## Components

### Task Commands

- `task flux:flate-test`: validate all Kustomizations and HelmReleases render successfully.
- `task flux:flate-build`: build rendered Flux resources locally.
- `task flux:flate-diff`: diff rendered resources against a baseline checkout or supplied baseline path.

### Validation

`yayamlls` performs schema validation over the raw and rendered Kubernetes manifests:

```bash
task kubernetes:yayamlls
```

## Usage

Run the full flate test:

```bash
task flux:flate-test
```

Build a specific path:

```bash
task flux:flate-build path=./kubernetes/apps/network
```

Diff against `origin/main`:

```bash
task flux:flate-diff
```

Diff against an existing baseline checkout:

```bash
task flux:flate-diff path_orig=./default/kubernetes
```

## What It Tests

- Kustomization rendering.
- HelmRelease rendering.
- Resource syntax.
- Dependency resolution.
- CRD availability for configured API versions.

## GitHub Actions

The workflow in `.github/workflows/flux.yaml` installs `home-operations/flate/action` and runs `flate test all` plus `flate diff all` directly.

## Missing CRD Errors

If flate reports that an API version is unavailable, update `FLATE_API_VERSIONS` in `.taskfiles/Flux/Taskfile.yaml` and the matching CI commands in `.github/workflows/flux.yaml`.
