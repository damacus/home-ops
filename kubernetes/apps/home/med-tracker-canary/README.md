# Med Tracker Canary Demo

This is a synthetic, disposable demo environment. It never restores from
production and must contain no production-derived records, uploads, notification
destinations, database backups, object-store copy, or WAL archive.

The application runs with `DEMO_MODE=true` and displays the reset schedule. The
committed MedTracker demo dataset is the only recovery baseline. These accounts
use the synthetic fixture password `password`:

- `demo.owner@example.com`
- `demo.carer@example.com`

Test users can register notification destinations and receive canary reminders.
Those registrations are disposable and are removed by the next reset.

## Weekly And Manual Reset

The `med-tracker-canary-reset` CronJob runs every Sunday at 04:15
`Europe/London`. It uses the same `ghcr.io/damacus/med-tracker:beta` image as the
web and health controllers and invokes `bin/rails canary:demo_reset` outside
Solid Queue.

The reset service account can only read the canary web Deployment and patch its
scale subresource. A reset scales the writable web controller to zero, waits for
all web and in-Puma queue writers to stop, and keeps `/up` routed to the separate
queue-free health controller. The web controller returns only after every reset
invariant passes. A failed reset leaves normal demo traffic stopped.

To run the reset manually after the CronJob exists:

```fish
set reset_job med-tracker-canary-reset-manual-(date +%Y%m%d%H%M%S)
kubectl create job --namespace home \
  --from=cronjob/med-tracker-canary-reset \
  $reset_job
```

Inspect the Job logs and require a successful baseline result before proceeding.
If it fails, fix the reported safety or verification boundary and create a new
manual Job. Do not restore the web replica manually around a failed reset.

## First Deployment

Both Flux Kustomizations remain suspended while this manifest transition is
reviewed. Activate the environment through GitOps in this order:

1. Resume only `med-tracker-canary-db` and wait for the one-instance CNPG
   cluster, its primary database, and the cache, queue, and cable databases.
2. Confirm there is no Backup, ScheduledBackup, ObjectStore, Barman plugin,
   external production recovery source, RustFS credential, or canary bucket.
3. Resume `med-tracker-canary`, let `db:prepare` complete, and wait for the
   health-only `/up` controller.
4. Create one manual reset Job and require every post-reset invariant to pass.
5. Sign in with both demo roles and verify the scheduled and as-needed medication
   scenarios before treating canary as available.

## Recovery

Canary has no database backup. Recovery means suspending both Kustomizations,
removing only the canary CNPG and storage resources, then repeating the first
deployment procedure. CNPG initializes a blank PostgreSQL 18 database, the
application runs migrations, and the reset loads the committed baseline.

The production hostname, database cluster, PVCs, Kubernetes secrets, backups,
and `med-tracker-rw.home.svc.cluster.local` are never recovery inputs or reset
targets.
