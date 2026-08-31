# Task 2 report: scheduled cluster checks

## Delivered

- Replaced the four Mise facade wrappers with native tasks:
  `kubernetes:log-noise`, `kubernetes:check-kube-vip`,
  `kubernetes:alerts`, and `kubernetes:edge-smoke`.
- Added the hidden, reusable `kubernetes:cluster-health-build` Mise task. It
  declares the original Go sources and cached binary output, then builds
  `.cache/bin/cluster-health` with `-trimpath`.
- Kept the Task command names as one-way Task-to-Mise compatibility shims.
  `morning-check` can therefore continue to invoke its migrated edge and
  log-noise checks without a Mise-to-Task cycle.
- Added focused contracts using fake `kubectl`, `jq`, Mise, and Go build
  executables. No test contacted a Kubernetes cluster.
- Updated the current edge-routing documentation and the migrated Task task
  summaries to use canonical Mise invocations.
- Did not change the external Codex automation.

## Files changed

- `.mise/tasks/kubernetes/cluster-health-build`
- `.mise/tasks/kubernetes/log-noise`
- `.mise/tasks/kubernetes/check-kube-vip`
- `.mise/tasks/kubernetes/alerts`
- `.mise/tasks/kubernetes/edge-smoke`
- `.taskfiles/Kubernetes/Taskfile.yaml`
- `docs/EDGE-ROUTING.md`
- `tests/test_mise_scheduled_cluster_checks.py`

## RED evidence

Added `tests/test_mise_scheduled_cluster_checks.py` before the implementation,
then ran:

```text
$ pytest -q tests/test_mise_scheduled_cluster_checks.py
Pytest: 0 passed, 3 failed

1. test_scheduled_cluster_checks_are_native_mise_tasks_with_a_shared_cached_build
   AssertionError: assert False
2. test_native_tasks_route_to_external_commands_and_preserve_exit_status
   AssertionError: assert '' == '      1 alert output\n'
3. test_legacy_task_names_are_one_way_mise_shims
   assert 201 == 31
```

The failures proved the native shared build task did not exist, the facade
still routed through Task, and the legacy Task command was not a Mise shim.

## GREEN and verification evidence

```text
$ pytest -q tests/test_mise_scheduled_cluster_checks.py tests/test_mise_task_facade.py
Pytest: 5 passed

$ shellcheck .mise/tasks/kubernetes/cluster-health-build \
  .mise/tasks/kubernetes/log-noise \
  .mise/tasks/kubernetes/check-kube-vip \
  .mise/tasks/kubernetes/alerts \
  .mise/tasks/kubernetes/edge-smoke
# exit 0, no output

$ mise tasks info kubernetes:log-noise
Task: kubernetes:log-noise
Depends on: kubernetes:cluster-health-build

$ mise tasks info kubernetes:edge-smoke
Task: kubernetes:edge-smoke
Depends on: kubernetes:cluster-health-build

$ mise tasks info kubernetes:cluster-health-build
Task: kubernetes:cluster-health-build
Properties: hide
Sources: go.mod, cmd/cluster-health/**/*.go, internal/clusterhealth/**/*.go
Outputs: .cache/bin/cluster-health

$ mise tasks ls
# all four canonical Kubernetes tasks are listed; the build task is hidden

$ go test ./...
Go test: 51 passed in 4 packages

$ git diff --check
# exit 0, no output
```

The first sandboxed `go test ./...` attempt could not open the local Go build
cache. Re-running the same read-only command with cache access passed.

## Self-review

- Native tasks do not execute `task`; Task shims execute Mise only, so there is
  no recursion.
- `log-noise` and `edge-smoke` use the same cached binary and preserve direct
  checker output and exit status. The build task retains the original Go
  sources, output path, `-trimpath`, and missing-toolchain message.
- `check-kube-vip` and `alerts` retain their original read-only `kubectl`
  commands and alert formatting pipeline.
- The tests prove the command routes, argument forwarding, standard output,
  and non-zero checker status with fake external commands.

## Concerns

- The full Python suite remains blocked by an unrelated baseline failure in
  `tests/test_cilium_config.py`: it expects Cilium `1.19.5`, while the tracked
  HelmRelease is `1.20.1`. The focused migration tests and all other Python
  tests pass (`46 passed, 1 failed`).
- No live-cluster execution was performed; the native command wiring was
  verified only with fakes, as required.
- An unrelated `.serena/project.yml` modification remained unstaged and was
  deliberately left untouched, in line with the preserved Serena side-effect
  boundary.
