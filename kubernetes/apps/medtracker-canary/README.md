# MedTracker Loco demo

This public, synthetic demo uses `https://med-tracker-loco.damacus.io` and resets
every Sunday at 04:00 Europe/London. Data and accounts entered here are disposable;
never enter real clinical records. The dedicated `medtracker-canary` namespace,
database cluster, credentials and storage are separate from the existing
MedTracker service in `home`. The existing service is never a reset or recovery
target. There is no Rails data import or existing database adoption.

The Flux Kustomization enables the isolated application resources. Initialisation
and live acceptance are complete; the weekly reset CronJob is enabled.
All demo edits are disposable.

The initial guarded reset completed on 28 October 2026 at 23:22 GMT, including
capability preflight, migrations, synthetic seeding and the internal HTTP journey.
Public HTTPS sign-in and synthetic dose recording were verified at desktop and
mobile widths. Live probes allowed the demo database and internal smoke route;
connections to the Kubernetes API, existing MedTracker database, shared RustFS,
SMTP, push and AI endpoints timed out under the demo network policy. An unrelated
pod was denied server access even with a temporary server-only egress allowance.
The temporary probes and their policy were removed after acceptance.

The application is pinned to the checked multi-architecture image from MedTracker
commit `63a08c2f31ba350502809e8d46f06633f69005ae`:
`sha256:b4f81dfa49e15e41d3ed24fb9ca303131984922a467d54f90e4eb7e45ea654f4`.
The reset runner is pinned to the image from HomeOps commit
`051205f78449ed017dbe640e2fc9d892fc34f44b`:
`sha256:bd6a462322ac0d7fee84e54ed0532f5e1c8aef35c33de80dd5b750e920f7edc3`.
Both images are pinned directly in the demo manifests. Keep the application
deployment images and the reset runner's `LOCO_IMAGE` setting identical.

Before activation:

- Publish checked Loco and reset-runner images; update their existing image
  fields and the `LOCO_IMAGE` setting to the verified immutable registry digests.
- Create a dedicated `medtracker-canary` 1Password item with `reset_password`,
  `runtime_password`, `status_password`, `session_key`, `smoke_key` and `dose_signing_key`.
  Use independent credentials, a 64-byte Base64 session key and strong signing key.
- The configured canary seed and journey tasks require the seed-enabled MedTracker
  image. It must implement the read-only `canary-capabilities` task, the
  `canary_seed(scope,image,complete)` completion marker and the control-state
  admission gate. The pinned application image implements this contract.
- The gate must close normal server requests until control phase is `ready`;
  only authenticated internal smoke can enter `verifying`; read-only health
  probes may pass while its heartbeat is fresh (maximum 30 seconds).
  Worker/scheduler work must remain paused until the phase is `ready`.
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

## First initialisation

Pin the verified application and runner digests, then enable the demo Flux
Kustomization through GitOps while keeping the weekly CronJob suspended. Wait
for the dedicated CNPG cluster and ExternalSecrets to be ready. Initialise the
empty demo through the same guarded runner used for weekly resets:

```fish
task kubernetes:medtracker-canary-reset
```

Require the reset Job to complete, verify public HTTPS sign-in and a synthetic
dose, and check the allowed and denied network cases above. Then enable the
weekly CronJob through GitOps. Its first scheduled run is not the initialisation
step. Failed or interrupted runs require the recovery procedure above; do not
clear state or retry around a failed seed.

Run offline behaviour checks with `task kubernetes:test-medtracker-canary`.
Use the existing render/schema/Mondoo checks before enabling GitOps resources.
