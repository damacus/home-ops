# Task 4 report: Mise and Bash composition

## Mapping

| Public task | Implementation |
| --- | --- |
| `provisioning:build` | Bash invokes Docker doctor and submodule initialisation for live builds, then `go run ./cmd/provisioning build`; dry-run only invokes Go. |
| `provisioning:verify`, `flash`, `enrol`, `retire` | Direct Go command invocation with the existing flags and argument names. |
| `provisioning:stage` | Bash validates with `artifact validate`, uses `jq` for artifact paths, copies to a temporary NAS directory, revalidates, and atomically renames. |
| `provisioning:release` | Bash validates before constructing the `gh release create` array; dry-run emits the existing JSON plan. |
| `provisioning:docker:doctor`, `docker:usage`, `docker:purge` | Bash Docker capacity/reporting and scoped Armbian purge. Purge delegates source/command safety validation to `armbian check docker-purge`. |
| `provisioning:clean`, `artifacts:clean` | Bash cleanup with explicit paths below the Armbian checkout or provisioning artifact directory. |
| `provisioning:status`, `lima:remove` | Bash status reporting and typed, three-command Lima removal gate. |

## RED/GREEN

The starting task files dispatched to `provisioning/provision.py`. The replacement task entrypoints now use direct Go interfaces or Bash composition; no provisioning task references Python. The compatibility wrappers `provisioning/armbian-build/build.sh` and `verify-image.sh` were removed after the direct task paths were in place.

## Checks

- `mise tasks ls`: all 14 provisioning tasks parsed and retained their public names and descriptions.
- `bash -n`: all provisioning task scripts passed.
- `shellcheck`: all provisioning task scripts passed (with intentional SSH remote-command SC2029 suppressions).
- `mise run provisioning:build --dry-run | jq ...`: passed; emitted the Go build plan and did not run Docker or submodule mutation.
- `mise run provisioning:clean --dry-run | jq ...`: passed; emitted explicit scoped paths.
- `mise run provisioning:artifacts:clean --dry-run | jq ...`: passed.
- `mise run provisioning:docker:purge --dry-run | jq ...`: passed; emitted the scoped compile command and reclaim flag.
- `mise run provisioning:lima:remove --dry-run | jq ...`: passed; emitted exactly three permitted commands.
- `mise run provisioning:flash /tmp/missing.img.xz /dev/null --dry-run`: passed and preserved the Go dry-run JSON contract without reading the artifact.
- `go test ./...`: passed.
- `go vet ./...`: passed.
- `git diff --check`: passed.

## Safety evidence and limitations

Cleanup paths are explicitly rooted in `provisioning/armbian-build` or `provisioning/artifacts`; Docker purge has a dry-run branch and invokes the reviewed Armbian command check before mutation. Stage validates both before copy and after copy, and only then performs the atomic directory rename. Release validation completes before `gh` is constructed or executed. No live build, purge, cleanup, Lima deletion, stage, release, flash, enrolment, retirement, cluster mutation, push, merge, or PR operation was run.

Docker doctor, host status, and successful stage/release mutation were not run against live infrastructure. Mise emits an ambient Fish startup parse warning in this checkout, but task discovery and all exercised task results remained correct.

## Self-review

Public flags, usage arguments, descriptions, and `quiet=true` remain unchanged. Arrays and quoted expansions are used for command arguments and artifact members. The remaining Python module is outside Task 4 removal scope; Task 5 owns its deletion after the behavioural migration review.
