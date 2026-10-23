# MedTracker canary

The Flux Kustomization and weekly reset CronJob are suspended. Application
resources and resets stay disabled until explicitly enabled. All canary edits
are disposable.

Before activation:

- Publish a checked Loco image and reset-runner image; set
  `MEDTRACKER_CANARY_IMAGE` and `MEDTRACKER_CANARY_RESET_IMAGE` in the Flux
  substitution source to their immutable registry digests.
- Create a dedicated `medtracker-canary` 1Password item with `reset_password`,
  `runtime_password`, `status_password`, `session_key`, `smoke_key` and `dose_signing_key`.
  Use independent credentials, a 64-byte Base64 session key and strong signing key.
- The configured canary seed and journey tasks require the seed-enabled MedTracker
  image. It must implement the read-only `canary-capabilities` task, the
  `canary_seed(scope,image,complete)` completion marker and the control-state
  admission gate. Current MedTracker main does not implement this contract.
- The gate must close normal server requests until control phase is `ready`;
  only authenticated internal smoke can enter `verifying`. Worker/scheduler work
  must stop unless ready or the verifying heartbeat is fresh (maximum 30 seconds).
  Use the read-only control URL under `settings.canary`, not setup credentials.
  Show the weekly data-loss notice and `last_success`/`next_reset` on the UI.
- Confirm private/VPN access to `med-tracker-canary.ironstone.casa` and Sunday
  04:00 Europe/London. Neither is an owner-approved live access/schedule decision.
  Verify Gateway namespace admission and reject untrusted external access.
- Check allowed gateway/smoke-to-server, app-to-canary-DB, operator-to-DB,
  CNPG-to-API and DNS traffic in isolation. Prove app-to-API, production databases,
  shared storage and Internet mail/push/AI traffic are denied.

The runner first validates its exact control address and pinned image, takes a
PostgreSQL advisory lock and checks the durable ownership marker and orphan Jobs.
It checks application capabilities before recording a run, fences the runtime
login, waits for old app pod UIDs to exit, recreates only `medtracker_canary` from
`template0`, and runs migrations and the application seed. It requires the seed
completion marker before restoring the restricted runtime login and running the
application journey task. Successful duplicate weekly runs are no-ops.

An interrupted/failed reset blocks all later resets. Inspect its Jobs and logs,
stop any orphan setup process and confirm the runtime login is fenced before
approving recovery. Never clear control state merely to retry a failing seed.
The runner does not delete namespaces, database clusters, PVCs, storage objects
or production data, or read Kubernetes Secrets through the API.

`mailer.stub: true` captures mail in process; no SMTP/push delivery is enabled.
Avatar/dm+d storage and their scheduled external work are excluded initially.
Synthetic seed acceptance covers sign-in, household selection, medication setup,
dose recording with stock changes, and one allowed/denied care permission case.

Run offline behaviour checks with `task kubernetes:test-medtracker-canary`.
Use the existing render/schema/Mondoo checks before enabling GitOps resources.
