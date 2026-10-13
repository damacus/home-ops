# RustFS SSD production cutover

## Current stage — 13 October 2026

Production `storage/rustfs` still uses `rustfs-data-hdd`. The second deployment,
`storage/rustfs-dr`, uses the populated `rustfs-dr-data-ssd` claim. This change
must not be activated until the copy and final verification below are complete.

The initial current-object comparison found 150,159 missing destination objects,
totalling 255,786,167,630 bytes. Replication configuration alone had not copied
that older history. The sole active copy Job is
`storage/rustfs-retirement-seed-v9`, UID
`4170de0e-240e-4f8f-9184-2152be25cab2`. It uses eight workers, a bounded queue of
32 tasks and one concurrent large-object copy. Conditional writes protect
objects that arrive through replication. The copy is processing `cnpg-zitadel`
and will continue through the remaining buckets. It remains active; this is not
a successful final audit or a production cutover.

The v9 online seed skips six buckets already seeded by predecessors. This is
only an online-copy optimisation. The required final convergence audit must
revisit all 21 source-authoritative buckets, including those six, after writers
are quiescent. Preserve the three buckets already authoritative on SSD:
`cnpg-cinc-registry`, `cnpg-n8n` and `cnpg-mealie`.

Verification checkpoints are stored under `migration-evidence/retirement/` in the
existing SSD bucket `dr-replication-trial-20261012`. Earlier worker Jobs are
suspended. Their completed verification records were retained separately.

The previous seed stopped after the HDD source exceeded its 2 GiB memory limit
at 05:08:41 UTC on 13 October. The separate memory fix is now deployed: production
and trial Deployment templates and Ready pods have a 1 GiB memory request,
6 GiB limit and `Recreate`. Production continues using the HDD claim.

This is a current-object migration. It does not establish parity for every old
object version. Keep the HDD data after the service cutover.

User-metadata header names are case-insensitive. The corrected comparator
normalises names while retaining exact values and system headers, and rejects
conflicting case variants. The initial 460 OCI and 31 Forgejo differences passed
independent SHA-256, metadata and tag verification with zero errors. These
bounded checks do not replace the final audit while writers remain active.

Read-only SHA-256, metadata and tag verification is still running for 30 existing
Home Assistant backup objects with differing multipart ETags. Its backup bucket
is one of the six predecessor-seeded buckets. This pending check concerns backup
objects, not Home Assistant configuration or volume migration; that separate
Longhorn migration completed in PR #4487.

The prepared final audit is
`/private/tmp/rustfs-retirement/audit_convergence.py`. It compares current keys,
sizes and ETags across every source-authoritative bucket. Where ETags differ,
it requires matching SHA-256 verification evidence for the current source and
destination objects. Missing objects, extra destination objects or unresolved
differences fail the audit. Writer quiescence must be verified separately; the
audit cannot establish it. Preserve its evidence before retiring either store.

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
   the initial comparison. Require the current copy Job to complete successfully.
   Review skipped/changed objects and errors. Online skips and size/count equality
   are insufficient evidence for the final swap.
2. Capture the current Flux, workload, CronJob and backup schedule state. Suspend
   the relevant reconcilers before a manual pause so they cannot undo it.
3. Pause new backup jobs and wait for active jobs to finish. Stop other S3 writers.
   Pausing CNPG ScheduledBackups does **not** pause continuous WAL archiving:
   temporarily disable the seven HDD backup accounts while their databases stay
   running, pause IAM jobs that could re-enable them, and monitor WAL headroom.
4. Finish the last copy and run the full convergence audit over all 21
   source-authoritative buckets, including the six skipped by the online seed.
   Require zero missing, extra or unresolved objects and matching SHA-256 proofs
   for differing ETags. Verify writer quiescence separately. Treat SSD as
   authoritative for Cinc Registry, n8n and Mealie. Reconcile source-side deletions
   deliberately; never blindly overwrite their newer SSD history with HDD data.
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
