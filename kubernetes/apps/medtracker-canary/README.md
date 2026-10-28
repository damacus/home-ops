# MedTracker Loco demo

This public, synthetic demo uses `https://med-tracker-loco.damacus.io` and resets
every Sunday at 04:00 Europe/London. Data and accounts entered here are disposable;
never enter real clinical records. The dedicated `medtracker-canary` namespace,
database cluster, credentials and storage are separate from the existing
MedTracker service in `home`. The existing service is never a reset or recovery
target. There is no Rails data import or existing database adoption.

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
- Verify public HTTPS access to `med-tracker-loco.damacus.io`, certificate coverage,
  DNS ownership and Gateway namespace admission. Direct access to the server from
  unrelated pods must remain blocked; only the gateway and internal smoke job may
  reach it. No private/VPN restriction is intended for the demo route.
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

The canary omits the optional queue reaper so a job waiting through an admission
pause cannot be claimed by another worker. After a worker crash, confirm the old
worker has terminated before using native job recovery, or let the next weekly
reset replace the disposable queue.

Run offline behaviour checks with `task kubernetes:test-medtracker-canary`.
Use the existing render/schema/Mondoo checks before enabling GitOps resources.
