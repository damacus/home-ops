# Task 5 Report: Migration Cleanup, CI, Documentation, And Full Integration

## Changes

- Deleted the obsolete Python controller at `provisioning/provision.py`.
- Deleted the obsolete Python regression suites at
  `tests/test_radxa_image_migration_contract.py` and
  `tests/test_provisioning_bash_tasks.py`.
- Retained the meaningful Docker doctor and Docker.raw usage coverage as Go
  integration tests in `internal/provisioning/bash_tasks_integration_test.go`.
- Added a Go rootfs fixture regression proving `PermitRootLogin yes` is
  rejected. The controller's real build then established that Armbian's main
  SSH config ordering made the overlay value ineffective; Fix Round 2 now
  enforces the policy in the main config before included drop-ins.
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
| `mise run provisioning:docker:doctor` | PASS in the controller environment outside the sandbox (`aarch64`, 8.32 GB memory, 284531892 KiB host space); the earlier local sandbox attempt was blocked by Docker daemon socket permissions. |
| `mise run provisioning:docker:usage` | BLOCKED: Docker daemon socket permission denied. |
| `mise run provisioning:build -- --dry-run` | PASS: resolved K3s `v1.36.3+k3s1`, ARM64 vendor/Noble plan, and `nvme-rescan` extension without network or Docker changes. |
| `mise run provisioning:enrol example.invalid --node-ip 192.0.2.10 --dry-run` | BLOCKED: Kubernetes API network access denied before discovery; no token read. |
| `mise run provisioning:status` | BLOCKED: Kubernetes API network access denied. |

## Existing artifact and real-build gate

The existing artifact set at
`/Users/damacus/.codex/worktrees/8c25/home-ops/.cache/radxa-build-3023c88/provisioning/artifacts/radxa-5b-plus-20260830-fa5068e61675.img.xz`
passed artifact-set validation through the stage/release dry-run plans, which
resolved its image, checksum, and manifest. The controller subsequently ran
Docker doctor successfully (`aarch64`, 8.32 GB memory, 284531892 KiB host
space), built commit `48fdc1dc9cf0` successfully in 3:37, and produced
`/Users/damacus/.codex/worktrees/8c25/home-ops/.cache/radxa-go-build-worktree/provisioning/artifacts/radxa-5b-plus-20260831-48fdc1dc9cf0.img.xz`.
Full read-only verification of that artifact failed only at effective
`PermitRootLogin=yes`; all other strengthened checks passed. This confirmed a
source defect in the build ordering, now fixed in Fix Round 2. A post-fix
rebuild and verification remain outstanding.

The initial local Docker and Kubernetes checks were sandbox-blocked; Docker is
no longer the current blocker for the source fix because the controller has
completed a successful build. No purge, cleanup, Lima operation, flash,
enrolment, retirement, cluster mutation, staging, release, push, merge, or
publication was attempted.

## Limitations and self-review

- The controller's successful build does not replace post-fix artifact
  verification or live lifecycle checks.
- Kubernetes API access remains an environmental blocker for the live enrolment
  dry-run; that check has not yet been retried after the controller build.
- The final diff was manually checked for stale Python dispatch. No absence or
  source-scan test was added, and no Python provisioning entrypoint remains in
  the current runtime paths.
- The current Go verifier checks the executable rootfs NVMe hook and a generated
  initramfs entry. The docs now describe that exact boundary.

## Fix Round 3

- Made the main-config `PermitRootLogin no` insertion idempotent: the
  customiser now checks line 1 before prepending, so repeated customisation
  does not accumulate duplicate global directives.
- Added focused coverage for the repeated-policy result alongside the existing
  main-file-before-include precedence regression.
- Corrected the earlier artifact assessment: the controller's real build from
  `48fdc1dc9cf0` succeeded, and its full verification confirmed the source
  ordering defect rather than a stale-artifact-only finding. The post-fix build
  and verification are still outstanding.
- Validation for this round: focused test, full Go test/vet/build, ShellCheck,
  Bash syntax, `jq` ledger validation, and `git diff --check` all pass. Both
  affected ledger entries remain `false`.

## Fix Round 1

- Corrected the golden-image artifact integrity ledger entry to `passes: false`.
  The existing artifact has the known effective `PermitRootLogin=yes` finding,
  and at that point full read-only verification remained blocked by Docker
  access. The later controller build and verification confirmed this was a
  source ordering defect; the post-fix artifact check remains outstanding.
- Corrected the Mise provisioning command contract ledger entry to `passes: false`.
  Its required live enrolment dry-run was blocked by Kubernetes API access; the
  controlled Go enrolment coverage remains green, but that does not satisfy the
  live acceptance check.
- Validation: `.tasks/provisioning.json` parses successfully with `jq`, and
  `git diff --check` passes.

## Fix Round 2

The first rebuilt artifact from commit `48fdc1dc9cf0` exposed a real source
defect. Its full read-only report failed only `ssh_policy`:
`PasswordAuthentication=no, KbdInteractiveAuthentication=no,
PermitRootLogin=yes`. The Armbian pinned source's
`lib/functions/rootfs/distro-agnostic.sh` rewrites the main
`/etc/ssh/sshd_config` to `PermitRootLogin yes` during image preparation.
OpenSSH evaluates the first value and does not let the later included
`sshd_config.d/00-ironstone-hardening.conf` value override it.

The narrow fix inserts `PermitRootLogin no` as the first line of the main
config after the overlay is copied in `customize-image.sh`, so it wins over any
existing directive or included file. The verifier remains unchanged. A new Go
fixture reproduces main-file `yes` before included `no` and confirms
verification fails at `ssh_policy`.

Validation after the fix:

- focused precedence and root-login verifier integration tests: PASS;
- `go test ./... -count=1`: PASS;
- `go vet ./...`: PASS;
- `go build ./cmd/...`: PASS;
- ShellCheck and `bash -n` for changed `customize-image.sh`: PASS;
- `git diff --check`: PASS.

No second real build was run. The controller must rebuild this commit and
re-run full artifact verification before either affected ledger entry can be
marked passed; the existing artifact and live enrolment acceptance boundaries
remain unchanged.
