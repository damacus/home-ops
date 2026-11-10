# Flate Local Testing Setup

This repository uses [flate](https://github.com/home-operations/flate) to render and validate Flux configurations locally before pushing to GitHub. The local task names match the GitHub Actions workflow.

## Components

### Task Commands

- `task flux:flate-test`: validate all Kustomizations and HelmReleases render successfully.
- `task flux:flate-build`: build rendered Flux resources locally.
- `task flux:flate-diff`: diff rendered resources against a baseline checkout or supplied baseline path.
- `task flux:flate-source-test`: verify candidate/baseline source selection and failure on missing manifests.

These commands use `scripts/flate-snapshots.mjs`. The helper creates ordinary Git snapshots so Flate can read the repository metadata, including when the original checkout uses Git worktrees. Each snapshot's `main` reference selects its own files, and the current snapshot includes local edits.

`scripts/flate-entry.yaml` places Flux configuration, the application controller and repository definitions in one render graph. Each snapshot uses its own version of this entry. Older commits that predate the entry use the current entry as a compatibility fallback.

A checkout without `origin` uses the canonical HomeOps source URL. Set `FLATE_SELF_URL` when testing another repository. `FLATE_BINARY` can select a specific installed Flate binary.

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

The workflow in `.github/workflows/flux.yaml` installs the pinned `home-operations/flate/action` release and runs `scripts/flate-snapshots.mjs` in `test` and `diff` modes. The helper invokes Flate with the same API-version configuration as the local Task commands and preserves failures from the renderer. CI also runs the source-selection regression.

## Missing CRD Errors

If flate reports that an API version is unavailable, update `FLATE_API_VERSIONS` in `.taskfiles/Flux/Taskfile.yaml` and the matching CI commands in `.github/workflows/flux.yaml`.
