# Disposable Loco canary proposal

Status: draft design for owner review, updated 23 October 2026. No deployment, reset,
secret creation or application change is authorised by this document.

## Outcome and current evidence

Run an isolated, synthetic MedTracker instance to discover whether a fresh Rust
database seeds reliably and supports ordinary user journeys. Reset its application
data weekly. All tester edits are disposable; production and retained Rails data
are outside this design. Rust-created data has no Rails reverse migration. Any
future retention/export request needs a separate decision before a reset.

Checked sources:

- HomeOps `kubernetes/apps/home/med-tracker/app/helmrelease.yaml` still declares
  Rails `0.5.35` at digest `f47f317657236675427f6b60761858f8203c0f44c1755ea16b5f926058c73925`.
  Its Rails commands, port 80, shared home namespace, queue databases and storage
  are not a Loco deployment template. Ironstone read-only discovery on 22 October found its two
  production Deployments ready and no dedicated canary namespace.
- [HomeOps #4523](https://github.com/damacus/home-ops/pull/4523) was confirmed merged
  at `ecead2c918c7ac2a9faa8d68881e8e00e7d9819a`. The current tree has no MedTracker
  canary definitions. Do not restore the retired reset service or Rails fixtures.
- [MedTracker #2867](https://github.com/damacus/med-tracker/pull/2867) merged at
  `66e8f67cc39aaafa3ca111d31047612e8169f373`. Main's
  [`Dockerfile`](https://github.com/damacus/med-tracker/blob/957e573901aee3c77836c9d3533c2dda6c17dc3f/Dockerfile),
  [image guide](https://github.com/damacus/med-tracker/blob/957e573901aee3c77836c9d3533c2dda6c17dc3f/docs/operations/loco-images.md)
  and publisher define a separate `ghcr.io/damacus/med-tracker-loco` image.
  It is scratch, UID/GID 65532, production config only, with no shell or fixture
  YAML. Main-only manual publication is opt-in, not triggered by merging.
- On 23 October, no runnable registry digest was verified. The package API returned
  404, which can mean absent or inaccessible; no manual publisher run was listed.
  Latest completed observed [image run](https://github.com/damacus/med-tracker/actions/runs/39883938947)
  passed amd64 and arm64 smoke jobs, failed image transfer verification and
  skipped publication. Fixing that failure and explicitly publishing a tested
  main revision belongs to MedTracker, before implementation selects an image.
- Image and seed contracts were rechecked against MedTracker main revision
  `957e573901aee3c77836c9d3533c2dda6c17dc3f` on 23 October. Its existing disposable PostgreSQL 18,
  template-clone and restricted-runtime test patterns are useful references.

## Proposed boundary

Create namespace `medtracker-canary`, with its own app-template HelmRelease,
single-instance CNPG PostgreSQL 18 Cluster `medtracker-canary`, 2 GiB
`openebs-hostpath` PVC and dedicated credentials. Reuse the existing CNPG operator,
PostgreSQL image catalogue, External Secrets/1Password mechanism, internal TLS
gateway and monitoring. Do not reuse production database roles, credentials,
session/signing keys, bucket identities or PVCs. Namespace pruning is disabled,
as in current namespace conventions; weekly reset has no namespace/PVC/Cluster
delete permission. No backup plugin, scheduled database backup or VolSync is
required for synthetic disposable data.

Recommend private-network/VPN access at `med-tracker-canary.ironstone.casa` through
`network/traefik-internal`, with local synthetic login. Domain availability and
Gateway allowedRoutes for the new namespace must be checked before activation.
Do not create public external-dns annotations or connect production Zitadel.
Private DNS alone is not an access control: enforce the existing private edge
boundary and prove an untrusted external client cannot reach this hostname.
Public invited-tester access is an outstanding owner choice.

Use one server, one worker and exactly one scheduler, all the same immutable
multi-architecture index digest and revision. Use Recreate for each Deployment,
one replica, no autoscaler and no overlapping scheduler rollout:

| Role | Arguments | Credential |
| --- | --- | --- |
| Server | `start --environment production` | Restricted runtime |
| Worker | `start --worker --environment production` | Restricted runtime |
| Scheduler | `scheduler --environment production` | Restricted runtime |
| Migration Job | `db migrate --environment production` | Setup/migration only |
| Seed Job | Application-owned canary task, not yet implemented | Seed/setup only |

Do not start the root worker Task (which also starts a scheduler). Configure
`BINDING=0.0.0.0`, port 5150, the canary public origin, Europe/London, secure cookies,
unique persistent session and dose-signing keys, and PostgreSQL-backed queue.
Keep startup auto-migrate, truncate and recreate disabled. Use read-only roots,
dropped capabilities, RuntimeDefault seccomp, `/tmp` emptyDir and UID 65532.
Server startup/readiness probes use `/health`; verify database/seed readiness
separately rather than assuming that endpoint proves either. Supervise worker and
scheduler termination/restarts; HTTP probes cannot prove those roles work.

Begin with proposed requests of 25m/64 MiB per app process, limits 500m/256 MiB;
PostgreSQL 100m/128 MiB request and 1 CPU/512 MiB limit. The reset coordinator
and each migration/seed/smoke child Job request 100m/128 MiB and limit 1 CPU/512 MiB.
The coordinator stays running while one child runs; children are sequential.
The simultaneous footprint is therefore 375m/576 MiB in requests and
4.5 CPU/2304 MiB in limits: three app pods, PostgreSQL, coordinator and one child.
Namespace quota caps limits at 6 CPU/4 GiB and storage at 4 GiB. This also admits
three old terminating app pods alongside their replacements (450m/768 MiB in
requests; 6 CPU/3072 MiB in limits). Wait for each child pod to become terminal
before creating the next; a completed Job object does not reserve pod quota.
Do not overlap a PostgreSQL replacement with reset work. If database recovery
needs extra quota, stop child work and recover the database before resuming;
never raise quota automatically. Account for rendered init-container resources
and any added sink/sidecar before activation; these totals assume none are added.
Bound pod/Job object counts to admit these concurrent and retained objects.
These are starting budgets, not measured Loco usage; adjust from observed OOMs,
startup and reset duration without changing isolation. No extra Redis is needed.

Default-deny ingress and egress for every canary pod, with separate allowances:
gateway to server:5150; app/setup pods to canary PG:5432; DNS to cluster DNS;
monitoring only to selected metrics endpoints; smoke Job to server:5150 and the
read-only status identity to the control DB. Server/worker/scheduler and seed/smoke
pods remain denied Kubernetes API access. Add separate CNPG management allowances,
scoped to pods labelled `cnpg.io/cluster=medtracker-canary`:

- Permit ingress on TCP 8000 (instance status) and 5432 from the operator in
  namespace `database`, matching both `app.kubernetes.io/name=cloudnative-pg` and
  `app.kubernetes.io/instance=cloudnative-pg`. Check the operator's own egress
  policies permit this direction too; do not allow the whole database namespace.
- Permit those CNPG pods and the reset coordinator to reach only the Kubernetes
  API. Scope the rule to the actual API identity/endpoints and TCP ports seen by
  Cilium after service translation; repository Cilium values declare
  `192.168.1.220:6443`. Verify the current endpoints and enforcement before
  implementation, rather than allowing Internet-wide 443/6443. CNPG's instance
  manager needs API access for reconciliation/coordination; app pods do not.
- Permit same-cluster CNPG pod traffic on TCP 5432/8000 for instance management
  and replacement, restricted by the cluster label, plus monitoring ingress to
  database metrics TCP 9187. Keep DNS allowance restricted to cluster DNS.

Read-only Ironstone inspection on 22 October found operator image
`ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1` (Helm chart 0.29.1), the above operator
selectors, and existing DB pods with `cnpg.io/cluster` labels. These management
ports match the versioned [CNPG networking guide](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/networking.md)
and [port table](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/security.md#exposed-ports).
The existing API-server-to-operator webhook path on TCP 9443 is outside the new
namespace and must remain intact; do not grant app pods access to it. No backup
plugin/object-store management allowance is needed for this plugin-free canary.
Recheck these requirements if the installed operator changes. Static inspection
does not prove live policy enforcement: verify operator status extraction, DB
API access and the intended app API denial in the isolated/approved environment.
Deny production databases, all other application traffic across namespaces,
production object storage, Internet SMTP/push, identity providers and AI APIs.

Initial journeys do not need avatars or dm+d imports: leave private S3 settings
unset and disable related scheduled external work in a mounted canary production
configuration. Prove normal startup accepts that configuration. If required by
startup or an explicitly included journey, add a canary-only object store and
bounded PVC; do not silently grant production/shared-bucket access. Record such
coverage as excluded until that path works. No real email or browser push sends:
use the application's supported stub/outbox transport if verified, otherwise a
canary-local mail sink with no relay and a MedTracker-owned capture transport.
Keep push signing keys absent and block push provider egress. Reminder intent can
be tested independently of physical delivery; do not claim delivery acceptance.

Image updates are explicit HomeOps PRs pinning a tested `sha-<full-commit>` and
its resolved index digest. No mutable main/latest tracking or unattended Renovate
rollout. Update server/worker/scheduler/migrate/seed together. Only activate an
image change outside an active reset; the coordinator verifies a single expected
digest throughout, and fails closed on mismatch. Weekly reset is independent of
whether the image changed.

## Weekly reset and failure behaviour

Recommend Sunday 04:00 Europe/London: CronJob `0 4 * * 0`, `timeZone:
Europe/London`, `concurrencyPolicy: Forbid`, `startingDeadlineSeconds: 1800`,
`backoffLimit: 0`, and an overall 20-minute deadline. Confirm the owner's preferred
time before activation. Forbid alone does not exclude duplicate/manual Jobs;
Kubernetes [requires idempotent Job behaviour](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/).

HomeOps owns one small reset coordinator and its GitOps-managed CronJob. It uses
a persistent control database in the dedicated canary PG Cluster, separate from
the disposable application database, to record run ID, phase, expected image,
seed version, epoch, last success and next due time. It holds a session advisory
lock there throughout the run. The next reset refuses any unfinished/failed run
until an owner explicitly approves recovery; a lost coordinator cannot silently
start a competing reset. This control record has bounded history (eight runs).

The coordinator's ServiceAccount has namespace-local list/get/delete of canary
app pods and get/create/delete/watch of its setup/smoke Jobs. Dynamic Job creation
cannot be name-restricted by RBAC: dedicated namespace isolation is essential.
No Secret reads, pod exec, Deployment scale/patch, HelmRelease/Flux patch, CRD,
Cluster, PVC, namespace or cross-namespace permissions. Jobs mount predeclared
canary setup credentials directly. App pods have no API token. The reset image
must be built/pinned through the repository's normal delivery flow, not install
tools into the shell-less Loco container. This is a bounded workflow, not a new
general-purpose deployment controller.

1. **Preflight and lock:** acquire the PostgreSQL lock, require no unfinished run
   or orphan setup Job, record a new run, and verify hard-coded namespace, CNPG
   service, application DB name, ownership marker and expected image digest.
   Reject arbitrary DSN/database/bucket overrides. Check before every destructive
   phase. The control connection never uses the DB that will be replaced.
2. **Fence writers:** make the canary runtime login `NOLOGIN`, revoke its app DB
   connect permission and terminate its existing sessions. CNPG managed-role
   configuration must not reconcile that runtime login back to LOGIN: this field
   has one lifecycle owner, the coordinator. Setup and control use
   different identities. Wait for zero runtime sessions; abort on failure.
   PostgreSQL fencing, not a probe or a replica count, prevents further writes.
3. **Quiesce processes:** delete the server/worker/scheduler pods gracefully and
   wait for every pre-fence pod UID to disappear. Replacement pods may be created
   by their Deployments, but cannot connect while fenced. Termination must complete
   before proceeding; do not force-delete a stuck pod to make the check pass.
   Existing network denial prevents queued work from sending externally.
4. **Create a fresh application DB:** drop only the exact canary application
   database, recreate it from `template0`, then install the normal application
   migrations through the pinned Loco migration Job. Keep control DB, PG cluster,
   PVC and all unrelated resources intact. PostgreSQL documents
   [`template0` as the pristine source](https://www.postgresql.org/docs/18/sql-createdatabase.html).
   Reapply restricted runtime grants for tables, sequences and queue; it inherits
   `med_tracker_app`, with no owner membership, superuser or BYPASSRLS.
5. **Seed once:** run the pinned application's canary seed task against the empty
   DB. Use deterministic identities and a recorded seed epoch for relative dates;
   update sequences after explicit IDs. Write a completed seed-version marker
   only after the entire seed transaction and its invariants succeed. A completed
   matching seed invocation is a no-op; partial/unrecognised population fails.
   No table-wide truncate or best-effort upsert over tester edits.
6. **Check before reopening:** verify schema version, seed marker, restricted-role
   grants and core fixture relationships. Ensure setup Jobs have exited. If
   canary-local blobs are introduced, delete only the exclusively owned bucket
   or local data path while fenced and before seeding; no shared-prefix wildcard
   cleanup. No object deletion exists in the initial configuration.
7. **Start and accept:** restore runtime login/connect, allow replacement pods to
   boot, and use bounded polling for server readiness and worker/scheduler
   availability. Run the small application-owned journey smoke described below
   through the internal service. Its Kubernetes identity has no setup privileges.
   Runtime access is only within the canary boundary. If checks fail, fence again
   and close access; don't leave a partly seeded instance presented as healthy.
8. **Complete:** record success, actual reset time, next weekly due time and image/
   seed revision; release lock. A duplicate completed weekly run is a no-op.

User access must remain closed until step 7 smoke passes: add an application-owned
canary admission/status gate driven by the control state (maintenance HTTP 503
for normal requests; internal authenticated smoke access only). This is an
implementation prerequisite, not an existing feature. Database login fencing
provides write safety even if the gate is stale; it does not by itself hide pages.
The app's status reader has read-only access to the control record, not reset
authority. Expose no internal DSNs, run tokens or credentials in the status UI.
Worker and scheduler admission must also check durable reset state before taking
new work; the short verifying phase has an expiring coordinator heartbeat. On
heartbeat expiry they stop taking work. This prevents a crashed coordinator from
leaving background processing enabled indefinitely before acceptance.

No unconditional finally block re-enables login. On handled timeout, lock loss,
migration, seed or smoke failure, reapply the fence and leave the durable
failed/unfinished marker and maintenance gate closed. If the coordinator dies
after reopening login for smoke, it cannot promise to execute that fence: durable
admission remains closed and the background heartbeat expires. Alert and fence
first during recovery; the fully seeded DB is preserved. Before a recovery
attempt, prove no predecessor or setup Job remains
active; stop orphan jobs, reacquire the lock and verify the fence. The same
approved run may resume from an explicit verified phase, or recreate its partial
application DB with owner approval. Do not automatically drop again on retry.
Test lock-loss/duplicate-job and failed-seed cases; a PostgreSQL lock alone does
not fence independently running child Jobs after the coordinator dies.

Keep one success Job and two failed Jobs, bounded structured phase logs without
passwords/tokens, and existing Loki retention. Retain failure Jobs for seven days,
unless the existing log policy is shorter; do not create database snapshots.
Alert through existing monitoring on reset failure, maintenance beyond 20 minutes,
no successful reset for eight days, app unavailable, or quota/OOM failures. The
status page shows “Synthetic canary — all edits erased weekly”, last reset,
next reset/countdown in London time, and failed/resetting state. Missed schedules
do not silently display an invented successful reset time.

## Seed adequacy and source ownership

Main's [`src/models/seed.rs`](https://github.com/damacus/med-tracker/blob/957e573901aee3c77836c9d3533c2dda6c17dc3f/src/models/seed.rs)
allows only Development/Test and refuses a DB containing accounts. It loads nine
domain fixture types plus `auth_credentials.yaml`, sets verified email from
account status, and is not an atomic/idempotent canary provisioner. Its account
check does not establish emptiness of every application table. Main's fixtures
provide one synthetic adult, one account and credential, one household with
administrator/self-manage membership, one cabinet, one medication (stock 10,
reorder threshold 10), and one assignment. The medication has a default schedule
field, but no realistic schedule matrix, dose history or reminder fixture graph.
The packaged image omits these YAML files. Do not bypass the production guard by
running development mode or reuse Rails' seeding runbook.

| Gap | Owner and smallest useful change |
| --- | --- |
| Runnable published image | MedTracker: fix transfer failure, explicitly publish checked main; HomeOps: verify both platforms and pin actual digest |
| Safe canary seed entry point | MedTracker: explicit synthetic-only task, packaged seed data, empty-DB/ownership guards, transaction, version marker, deterministic rerun semantics; keep ordinary production seed rejection |
| Household selection and permissions | MedTracker: two synthetic households, multi-household adult, another independently authorised adult, accountless dependent and valid guardian declaration, a limited viewer and unrelated denied household; use current domain invariants |
| Locations, medication and stock | MedTracker: labelled cabinet and supported unlabelled stock, scheduled and PRN medication, normal/low/zero stock and different units; verify current location lifecycle before including unlabelled scenario |
| Current journey data | MedTracker: assignments, active schedules, recent taken/skipped history, due/overdue doses and reminder intents anchored to the recorded reset epoch; no real subscriptions or provider calls |
| Empty/onboarding state | MedTracker: separate synthetic account that can complete the currently supported first household/medication journey |
| Safe runtime and external services | HomeOps: isolated PG/roles/secrets/policies/jobs; MedTracker: supported no-send mail capture, canary admission/status gate, config for disabled external scheduled work and optional S3 startup |
| Weekly lifecycle and visibility | HomeOps: coordinator, CronJob, least-privilege RBAC, alerts, budgets; MedTracker: banner/status and application journey smoke |

Seeding guardian, viewer and unlabelled scenarios is requested coverage, not proof
that every current UI path supports them. Validate against current application
models and existing browser journeys; report unsupported paths explicitly. Do
not implement new care/OAuth features as part of HomeOps work or compete with
their active owners. Use synthetic `.test` identities only; keep seed credentials
inside the private tester boundary and never copy production data.

Smallest acceptance: from a genuinely empty migrated DB, sign in with the normal
synthetic credential, select between households, view one dashboard, create a
medication/assignment, record one dose and observe the expected stock change.
Check one guardian-allowed action and one viewer/unrelated-household denial,
and verify due/history/reminder intent appears without external sends. The
onboarding account reaches its empty state normally. Repeat provisioning against
a second fresh disposable DB, and prove the completed same-version seed is a
no-op and partial population is rejected. Avoid a separate evidence framework:
extend the existing full-App::boot/restricted-runtime and browser journey tests,
plus image smoke tests. This checks seeded usability, not all application parity.

## Candidate configuration and implementation order

Proposed HomeOps paths (none created by this design):

```text
kubernetes/apps/medtracker-canary/kustomization.yaml
kubernetes/apps/medtracker-canary/namespace.yaml
kubernetes/apps/medtracker-canary/policy/{networkpolicy,quota,limitrange}.yaml
kubernetes/apps/medtracker-canary/database/ks.yaml
kubernetes/apps/medtracker-canary/database/app/{kustomization,cluster,externalsecret}.yaml
kubernetes/apps/medtracker-canary/application/ks.yaml
kubernetes/apps/medtracker-canary/application/app/{kustomization,helmrelease,externalsecret,configmap}.yaml
kubernetes/apps/medtracker-canary/reset/ks.yaml
kubernetes/apps/medtracker-canary/reset/app/{kustomization,cronjob,rbac,configmap,prometheusrule}.yaml
cmd/medtracker-canary-reset/
internal/medtrackercanaryreset/
```

Follow the active cluster-apps definition in `kubernetes/flux/cluster/ks.yaml`
(app path `./kubernetes/apps`) and the FluxInstance chart values in
`kubernetes/apps/flux-system/flux-instance/app/helm/values.yaml`; inspect rendered
discovery before adding a namespace root rather than editing the commented legacy
`kubernetes/flux/apps.yaml`. Namespace/policies precede DB; DB readiness precedes
application setup. CronJob stays suspended until initial provisioning, admission
gate, image and owner schedule/access decisions are accepted. Do not mark any
existing `.tasks` deployment objective passed for this proposal.

1. Resolve private/public access and weekly time with the owner before implementation.
   Confirm all canary edits are intentionally disposable in the UI, and obtain
   implementation approval for this proposed design.
2. MedTracker owner delivers the seed task, small fixture graph, gate/no-send
   configuration and existing-test extensions in scoped application changes.
   Publish an image containing those capabilities; current #2867 alone is insufficient.
3. After implementation approval, HomeOps adds isolated, initially disabled
   resources and the small coordinator with behavioural regression tests for
   target rejection, duplicate/reset lock loss, stale Jobs, failure fencing and
   exact data scope. Include an independent invariant denying Secret reads.
4. Use existing Flate/render, YAML/schema and Mondoo policy checks for manifests;
   no tests duplicating YAML values. Exercise the coordinator and application seed
   in the existing disposable environment patterns. Record allowed/denied network
   cases and prove them in isolation or after a separately approved rollout.
5. Review locally, then request publication/rollout only within the owner's
   authorised scope. Observe initial fresh seed and one approved reset; enable
   the weekly schedule only after those ordinary checks succeed.

Design verification performed: source inspection, merged PR/workflow/package API
reads and explicitly scoped Ironstone read-only discovery. Context7 was unavailable
because its monthly quota was exhausted; official Kubernetes/PostgreSQL docs were
used for reset semantics. No image was pulled/executed, no credentials inspected,
and no live access, seed, storage, reset or resource budget has been validated.
