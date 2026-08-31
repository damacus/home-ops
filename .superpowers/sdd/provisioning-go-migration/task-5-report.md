# Task 5 Report: Migration Cleanup, CI, Documentation, And Full Integration

## Changes

- Deleted the obsolete Python controller at `provisioning/provision.py`.
- Deleted the obsolete Python regression suites at
  `tests/test_radxa_image_migration_contract.py` and
  `tests/test_provisioning_bash_tasks.py`.
- Retained the meaningful Docker doctor and Docker.raw usage coverage as Go
  integration tests in `internal/provisioning/bash_tasks_integration_test.go`.
- Added a Go rootfs fixture regression proving `PermitRootLogin yes` is
  rejected. The current golden-image overlay already contains
  `PermitRootLogin no`; no overlay change was required for the known stale
  artifact finding.
- Updated `provisioning/README.md`, `provisioning/docs/README.md`,
  `provisioning/docs/initramfs.md`, `provisioning/docs/initramfs-investigation.md`,
  `GEMINI.md`, and `docs.txt` for Go/Mise/Bash ownership, deterministic
  `node-ip`, token-gated SSH enrolment, and rootfs plus initramfs NVMe
  verification. `docs.txt` and the `AGENTS.md` retention rule remain present.
- Extended `.github/workflows/flux.yaml` Go path filters to include
  `cmd/provisioning`, `internal/provisioning`, `.mise/tasks/provisioning`, and
  `provisioning/**`; CI now builds `go build ./cmd/...`.
- Updated the relevant `.tasks/provisioning.json` wording from the removed
  Python implementation to the Go command and Bash orchestration. No blocked
  build, hardware, or live lifecycle item was marked passed.

## Acceptance checks

| Command | Result |
|---|---|
| `go test ./... -count=1` | PASS |
| `go vet ./...` | PASS |
| `go build ./cmd/...` | PASS |
| ShellCheck on all repository-owned provisioning tasks and scripts | PASS |
| `bash -n` on all repository-owned provisioning tasks and scripts | PASS |
| `mise tasks validate` for all 14 provisioning tasks | PASS |
| Non-mutating build, flash, retire, stage, release, clean, purge, reclaim, Lima, and artifact-clean dry-runs with `jq` JSON checks | PASS |
| `git diff --check` | PASS |
| `task kubernetes:yayamlls` | PASS |
| `mise run provisioning:docker:doctor` | BLOCKED: Docker daemon socket permission denied; architecture and memory consequently report unknown/0. Host space reported 284529048 KiB. |
| `mise run provisioning:docker:usage` | BLOCKED: Docker daemon socket permission denied. |
| `mise run provisioning:build -- --dry-run` | PASS: resolved K3s `v1.36.3+k3s1`, ARM64 vendor/Noble plan, and `nvme-rescan` extension without network or Docker changes. |
| `mise run provisioning:enrol example.invalid --node-ip 192.0.2.10 --dry-run` | BLOCKED: Kubernetes API network access denied before discovery; no token read. |
| `mise run provisioning:status` | BLOCKED: Kubernetes API network access denied. |

## Existing artifact and real-build gate

The existing artifact set at
`/Users/damacus/.codex/worktrees/8c25/home-ops/.cache/radxa-build-3023c88/provisioning/artifacts/radxa-5b-plus-20260830-fa5068e61675.img.xz`
passed artifact-set validation through the stage/release dry-run plans, which
resolved its image, checksum, and manifest. Full read-only image verification
was blocked before mounting because Docker access failed with the same daemon
socket permission error. Task 2's completed verification evidence records the
real artifact finding as effective `PermitRootLogin=yes`; all other strengthened
checks passed. The current overlay is `PermitRootLogin no`, and the new fixture
regression passes, so this is a stale artifact finding rather than an unaddressed
source defect.

Because Docker doctor did not pass without cleanup, the conditional real build
was not run. No purge, cleanup, Lima operation, flash, enrolment, retirement,
cluster mutation, staging, release, push, merge, or publication was attempted.

## Limitations and self-review

- Docker daemon access and Kubernetes API access remain environmental blockers;
  static and controlled integration coverage does not replace those live checks.
- The final diff was manually checked for stale Python dispatch. No absence or
  source-scan test was added, and no Python provisioning entrypoint remains in
  the current runtime paths.
- The current Go verifier checks the executable rootfs NVMe hook and a generated
  initramfs entry. The docs now describe that exact boundary.
