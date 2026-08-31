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
  hardware or live lifecycle item was marked passed; the artifact contract was
  marked passed only after the controller's final artifact verification in Fix
  Round 6.

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
| `mise run provisioning:docker:doctor` | PASS in the controller environment outside the sandbox (`aarch64`, 8.32 GB memory, 280115420 KiB host space at final build start); the earlier local sandbox attempt was blocked by Docker daemon socket permissions. |
| `mise run provisioning:docker:usage` | BLOCKED: Docker daemon socket permission denied. |
| `mise run provisioning:build -- --dry-run` | PASS: resolved K3s `v1.36.3+k3s1`, ARM64 vendor/Noble plan, and `nvme-rescan` extension without network or Docker changes. |
| `mise run provisioning:enrol 192.168.1.233 --dry-run` | BLOCKED at target SSH authentication: `sign_and_send_pubkey ... from agent: communication with agent failed`; no mutation or token read. This is an SSH-agent environment boundary, not a code pass or failure. |
| `mise run provisioning:status` | PASS outside the sandbox: all three nodes Ready on `v1.36.3+k3s1`. |

## Existing artifact and real-build gate

The prior artifact set at
`/Users/damacus/.codex/worktrees/8c25/home-ops/.cache/radxa-build-3023c88/provisioning/artifacts/radxa-5b-plus-20260830-fa5068e61675.img.xz`
passed artifact-set validation through the stage/release dry-run plans, which
resolved its image, checksum, and manifest. Its known effective
`PermitRootLogin=yes` finding remains historical evidence for the source
ordering defect fixed in Fix Round 2. The controller then ran Docker doctor
successfully (`aarch64`, 8.32 GB memory, 280115420 KiB host space at final
build start) and built approved commit `8ecdf4ccdc5f` successfully in 3:21,
including `nvme-rescan` installation and customization. It produced
`/Users/damacus/.codex/worktrees/8c25/home-ops/.cache/radxa-go-build-worktree/provisioning/artifacts/radxa-5b-plus-20260831-8ecdf4ccdc5f.img.xz`.

Full read-only verification of the final artifact passed every check:
effective SSH policy was `PasswordAuthentication=no`,
`KbdInteractiveAuthentication=no`, `PermitRootLogin=no`; K3s
`v1.36.3+k3s1`, payload hashes, immutable cluster state, locked accounts,
dormant K3s, packages, unattended upgrades, compact rootfs, and the NVMe hook
embedded in initramfs all passed. This artifact satisfies the golden-image
integrity contract.

The controller also confirmed all three nodes Ready with K3s
`v1.36.3+k3s1`. The live enrolment dry-run reached target SSH but stopped at
`sign_and_send_pubkey ... from agent: communication with agent failed`; it did
not read a token or mutate state. No flash, retirement, cluster mutation,
staging, release, push, merge, or publication was attempted.

## Limitations and self-review

- The final artifact is fully verified read-only and satisfies the golden-image
  integrity boundary; hardware flashing and enrolment remain unverified.
- The live enrolment dry-run is blocked at SSH-agent authentication. This is an
  environmental boundary, not evidence that the enrolment code passed or
  failed.
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

## Fix Round 4

- Replaced the verifier-fixture self-check with a behavioural integration test
  that executes the production SSH-policy helper twice against a temporary
  config. It confirms the first effective directive is `PermitRootLogin no` and
  that the directive occurs once.
- Extracted the policy mutation into
  `provisioning/armbian-build/userpatches/overlay/usr/local/libexec/ironstone/ensure-root-ssh-policy.sh`;
  the image customiser calls this exact helper, which accepts the target config
  path for controlled testing without package, network, chroot, or system
  operations.
- Both affected ledger entries remain `false`; no real build or live operation
  was run.

Validation for this round:

- focused helper and SSH precedence integration tests: PASS;
- `go test ./... -count=1`: PASS;
- `go vet ./...`: PASS;
- `go build ./cmd/...`: PASS;
- ShellCheck and `bash -n` for all remaining provisioning shell tasks/scripts:
  PASS;
- `jq` ledger validation and `git diff --check`: PASS.

## Fix Round 5

- Corrected the Armbian packaging boundary exposed by the controller's
  post-fix build from `9ab98d47`: top-level userpatch files are not copied
  beside `/tmp/customize-image.sh`, producing
  `/tmp/customize-image.sh: line 53: /tmp/ensure-root-ssh-policy.sh: No such file or directory`.
- Moved the helper into the real overlay at
  `/usr/local/libexec/ironstone/ensure-root-ssh-policy.sh`, which is copied by
  the existing `/tmp/overlay` rsync before the customiser invokes it.
- Reworked the behavioural test to stage the complete repository overlay into
  a temporary rootfs, invoke the helper at that staged production path twice,
  and verify one first `PermitRootLogin no` directive. The test therefore
  covers helper availability and idempotency at the packaging boundary.
- Both affected ledger entries remain `false`; no real build or live operation
  was run.

Validation for this round:

- focused staged-overlay helper and SSH precedence integration tests: PASS;
- `go test ./... -count=1`: PASS;
- `go vet ./...`: PASS;
- `go build ./cmd/...`: PASS;
- ShellCheck and `bash -n` for all remaining provisioning shell tasks/scripts:
  PASS;
- `git diff --check` and `jq` ledger validation: PASS.

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

At that stage no second real build was run. Fix Round 6 records the
controller's successful rebuild and full artifact verification; the live
enrolment acceptance boundary remains unresolved.

## Fix Round 6

- Updated the current acceptance evidence with the controller's successful
  Docker doctor and real Armbian build from approved commit `8ecdf4ccdc5f`.
- Recorded the final artifact's full read-only verification: all SSH, K3s,
  payload, immutable-state, account, package, unattended-upgrade, compact
  rootfs, and NVMe initramfs checks passed.
- Recorded `provisioning:status` passing outside the sandbox for all three
  Ready nodes on `v1.36.3+k3s1`.
- Recorded the enrolment dry-run boundary accurately: target SSH authentication
  stopped at `sign_and_send_pubkey ... from agent: communication with agent
  failed`; no token was read and no mutation occurred. The Mise command
  contract therefore remains unpassed.
- Set only the golden-image artifact integrity ledger entry to `passes: true`.
  The broader Mise provisioning command contract remains `passes: false` until
  the enrolment dry-run completes.
- Validation: `.tasks/provisioning.json` parses successfully with `jq`, and
  `git diff --check` passes.
