# RustFS SSD production cutover

## Current stage — 13 October 2026

Production `storage/rustfs` still uses `rustfs-data-hdd`. The second deployment,
`storage/rustfs-dr`, uses the populated `rustfs-dr-data-ssd` claim. This change
must not be activated until the copy and final verification below are complete.

The initial current-object comparison found 150,159 missing destination objects,
totalling 255,786,167,630 bytes. Replication configuration alone had not copied
that older history. The in-cluster retirement copy Jobs copy missing current objects and verify
their contents with SHA-256, metadata and tags. Each worker uses conditional writes to avoid overwriting objects that arrive through
replication. The copy deliberately excludes the three buckets already authoritative on
SSD: `cnpg-cinc-registry`, `cnpg-n8n` and `cnpg-mealie`.

Verification checkpoints are stored under `migration-evidence/retirement/` in the
existing SSD bucket `dr-replication-trial-20261012`. Earlier worker Jobs are
suspended. Their completed verification records were retained separately.

The latest seed stopped after the HDD source exceeded its 2 GiB memory limit
at 05:08:41 UTC on 13 October. Production and the trial now require a 1 GiB
memory request and 6 GiB limit. Apply this resource change with `Recreate`
while copying is stopped, then verify both Deployment templates and Ready pods
before resuming a worker. A live pod resize alone is not durable.

This is a current-object migration. It does not establish parity for every old
object version. Keep the HDD data after the service cutover.

The previous worker stopped on 454 artifact metadata comparisons: one endpoint
returned `layer-digest`, the other `Layer-Digest`. User-metadata header names are
case-insensitive. The corrected comparator normalises names while retaining exact
values and system headers, and rejects conflicting case variants. All 454
artifacts passed independent content, metadata and tag verification after the
fix; five behavioural regression tests passed.

## Remaining HDD consumers

- CNPG backups and WAL: Zitadel, Forgejo, Northops, Home Assistant, Immich,
  MedTracker and Penpot.
- Longhorn backups and the Paperless VolSync/Restic repository.
- Loki, Tempo, Zot and Supermarket artifact storage.

Cinc Registry, n8n and Mealie already use the SSD HTTPS endpoint. Keep that endpoint
as a service alias after production adopts the SSD claim. Other clients retain
their existing production URLs; their endpoint manifests need no change.

## Completed preparation

- All ten CNPG accounts passed read/write/delete tests on their SSD buckets and
  were denied access to an unrelated bucket. Disposable probes were removed.
- Fresh SSD backup `dev/cinc-registry-ssd-retirement-202610121950` completed at
  19:50:23 UTC, Barman backup ID `20261012T195018`.
- All 25 source IAM policies and all 16 active user-policy mappings match SSD.
- The production OIDC provider, including its original secret and callback, was
  copied and verified. Production must start without the trial OIDC environment
  overrides. Interactive production login still needs checking after the swap.
- Source and destination bucket settings matched in 192 checks.
- All RustFS PVs currently use `Retain`.

The inactive `rustfs-cnpg-med-tracker-canary` user has no current Kubernetes
credential reference and is not recreated on SSD. Its original identity metadata
was preserved privately. Source IAM export also reports `policy does not exist`,
so persistent STS mappings are not fully inventoried. Retain the HDD metadata for
that investigation; no password was reset.

## Activation sequence

1. Refresh the live bucket and writer inventory, including services added since
   the initial comparison. Require the current copy Job to complete successfully. Review skipped/changed objects
   and errors, then compare current objects again. Size/count equality alone is
   insufficient; preserve checksum verification for multipart ETag differences.
2. Capture the current Flux, workload, CronJob and backup schedule state. Suspend
   the relevant reconcilers before a manual pause so they cannot undo it.
3. Pause new backup jobs and wait for active jobs to finish. Stop other S3 writers.
   Pausing CNPG ScheduledBackups does **not** pause continuous WAL archiving:
   temporarily disable the seven HDD backup accounts while their databases stay
   running, pause IAM jobs that could re-enable them, and monitor WAL headroom.
4. Finish the last copy and verify convergence. Treat SSD as authoritative for
   Cinc Registry, n8n and Mealie. Reconcile source-side deletions deliberately;
   never blindly overwrite their newer SSD history with the HDD copy.
5. Disable HDD replication rules. Scaling a deployment to zero stops replication
   activity but does not remove its persisted configuration.
6. Suspend the RustFS HelmRelease for the swap. Stop **both** RustFS deployments
   and wait for their pods to terminate. Never run two RustFS processes against
   the populated SSD claim.
7. Activate the production manifest using `rustfs-dr-data-ssd`, `Recreate`, and
   the compatibility service/routes. Keep the temporary trial deployment at zero.
   Automatic Helm rollback to an HDD-backed release is disabled.
8. Verify both endpoint names, application credentials, production OIDC login,
   object reads and writes. Resume writers and their original reconciliation and
   schedule state. Verify WAL archiving and run fresh backups on SSD.
9. Keep the HDD claims and data. Physical array retirement requires a separate
   check of remaining NAS shares, recovery coverage and historical versions.

The copy Job does not perform an unattended production cutover.
