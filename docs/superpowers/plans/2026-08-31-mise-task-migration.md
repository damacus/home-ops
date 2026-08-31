# Mise Task Migration

## Goal

Make Mise the public task runner for home-ops. Keep Task only behind workflows
that have not yet received a native Mise implementation. Deliver the migration
as a five-layer native GitHub pull-request stack.

## Global Constraints

- Use `mise run <namespace>:<task> [arguments]` as the canonical command.
- Use `mise tasks info <namespace>:<task>` for task information.
- Preserve existing arguments, standard output, standard error, and exit codes.
- Write a failing contract test before each production change.
- Do not run destructive or live-cluster operations merely to test task wiring.
- When a task becomes native, remove its Mise-to-Task wrapper and Task
  implementation in the same layer.
- If an unmigrated Task composite still invokes a migrated task, use a tested
  temporary Task-to-Mise shim and prevent recursion.
- Update tracked CI and documentation in the layer that changes a command.
- Preserve unrelated worktree changes.
- Use Conventional Commits and verify author, committer, and SSH signing
  identity before every commit.
- Subagents must not push, publish pull requests, merge, or update Codex
  automations.

## Task 1: Add the Mise facade

Create branch `codex/mise-task-facade` from `main`.

- Add a canonical Mise task for every public command returned by
  `task --list-all`, excluding Task's empty `default` listing command.
- Each facade entry must delegate to the same Task command and pass subsequent
  arguments verbatim. Use Mise's raw-argument mode where required.
- Copy the Task description into Mise so `mise tasks info` is useful.
- Do not expose Task's internal dot-prefixed tasks.
- Add contract tests which fail before the facade exists and verify complete
  public-task discovery, descriptions, argument forwarding, stdout, stderr,
  and non-zero exit-status preservation with a fake `task` executable.
- Keep every existing Task implementation unchanged in this layer.
- Verify the focused tests, `mise tasks ls`, `mise tasks info`, ShellCheck for
  any file tasks, and the repository's relevant full test suite.
- Commit the reviewed layer with a Conventional Commit.

## Task 2: Migrate scheduled cluster checks

Create branch `codex/mise-scheduled-cluster-checks` above Task 1.

- Replace the facade wrappers for these commands with native Mise tasks:
  `kubernetes:log-noise`, `kubernetes:check-kube-vip`,
  `kubernetes:alerts`, and `kubernetes:edge-smoke`.
- Preserve their command-line contracts, output, exit status, descriptions,
  Go build behaviour, and read-only operational behaviour.
- Where an unmigrated Task composite still calls one of these commands,
  replace that dependency with a tested Task-to-Mise shim.
- Remove the superseded Task implementations without creating cycles.
- Add failing routing and behaviour tests before implementation. Use fake
  external commands instead of the live cluster.
- Update tracked callers and documentation for these four commands.
- Verify focused tests, `go test ./...`, ShellCheck, Mise task discovery, and
  the relevant repository suite.
- Commit the reviewed layer with a Conventional Commit.

After Tasks 1 and 2 land on `main`, the controller must update the active
`check-for-cluster-issues` Codex automation. Replace Task commands with the
four canonical Mise commands and replace `task <command> --summary` guidance
with `mise tasks info <command>`. Preserve its active status, weekday 08:00
schedule, target thread, and remediation-plan requirement. Read the automation
back after updating it. This external update is not part of a git commit and
must not happen before the native commands are on `main`.

## Task 3: Migrate cluster health

Create branch `codex/mise-cluster-health` above Task 2.

- Move the shared Go binary build and cache contract to Mise using declared
  sources and outputs.
- Replace the remaining cluster-health facade wrappers with native Mise tasks:
  `health-nodes`, `health-kube-vip`, `health-cilium`, `health-pods`,
  `health-deployments`, `health`, `cnpg-health`, `cnpg-backups`,
  `gitops-health`, `external-secrets-health`, `service-account-health`,
  `grafana-alerts`, `morning-check`, `edge-smoke-esphome`, and `log-noise`.
- Preserve sequential composition, aggregated failure status, optional
  notification, every supported argument, and text or NDJSON output.
- Remove superseded Task implementations and internal cluster-health helpers.
- Add failing contract tests before implementation and extend Go tests where
  behaviour changes.
- Update tracked callers and documentation.
- Verify focused tests, `go test ./...`, ShellCheck, Mise discovery, and the
  relevant repository suite.
- Commit the reviewed layer with a Conventional Commit.

## Task 4: Migrate leaf operations

Create branch `codex/mise-leaf-operations` above Task 3.

- Replace facade wrappers with native Mise implementations for all `jq:*`
  tasks, `home-assistant:unaccounted-electricity`, `unifi:mesh-status`,
  `flux:flate-test`, `flux:flate-build`, `flux:flate-diff`,
  `certificates:check-certificates`, and `workstation:venv`.
- Also migrate these Kubernetes read-only tasks: `resources`, `yayamlls`,
  `rustfs-iam-policy`, `rustfs-iam-live-policy`, `forgejo-policy`,
  `tempo-trace-backend-contract`, `log-noise-by-namespace`, `test-app`,
  `mondoo-manifests`, and `mondoo-live`.
- Preserve arguments, working directories, prerequisites, platform behaviour,
  sources and outputs, and failure messages.
- Remove the superseded Task implementations.
- Update the Flux workflow and every tracked current command example in the
  same layer. Do not rewrite historical reports or archived plans.
- Add failing contract tests before implementation.
- Verify focused tests, relevant Python tests, ShellCheck, safe Flate and
  manifest checks, Mise discovery, and the relevant repository suite.
- Commit the reviewed layer with a Conventional Commit.

## Task 5: Migrate PostgreSQL workflows

Create branch `codex/mise-postgres` above Task 4.

- Replace every public `postgres:*` facade wrapper with a native Mise task.
- Keep `scripts/pg-bluegreen.sh` as the safety and implementation boundary.
- Preserve all existing environment variable names, profile loading, command
  ordering, output, exit codes, confirmations, and idempotency.
- Preserve serial `all-but-cutover` composition and SOP output.
- Remove the PostgreSQL Taskfile include and superseded Task definitions.
- Update current tracked callers, script guidance, manifests, and docs to the
  canonical Mise commands.
- Add failing tests for environment forwarding, subcommand forwarding,
  sequencing, failure propagation, and SOP output before implementation.
- Do not execute a live PostgreSQL migration or destructive subcommand.
- Verify focused tests, ShellCheck, Mise discovery, and the relevant full
  repository suite.
- Commit the reviewed layer with a Conventional Commit.

## Final Review and Publication

- Generate one whole-stack review package from `main` to the top branch.
- Run an independent Sol review. Apply at most one final fix wave followed by
  one scoped re-review.
- Verify every stack branch is linear and known-good.
- Submit draft pull requests with `gh stack submit --auto` only after GitHub
  CLI authentication works.
- Do not merge the stack without separate user authorisation.
