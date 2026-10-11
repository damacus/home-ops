# RustFS SSD migration

Target: `rustfs-data-ssd`, 500 GiB requested, `nfs-csi-ssd`, UID/GID 977:988.
Retain `rustfs-data-hdd` and its PV for rollback. The static migration source is
read-only at both the NFS mount and PVC layers.

## Procedure

1. Apply `app/ssd-storage.yaml` and `migration/volsync-source.yaml`. Run the
   preflight and `online-seed.yaml`. The original VolSync movers remain paused.
   The direct rsync job supports a precise temporary-staging exclusion which
   the installed VolSync rsyncTLS schema does not expose.
2. Immediately before final sync, check current CNPG, Longhorn and VolSync
   backups, not just cron times. Hold the RustFS and IAM Flux Kustomizations,
   hold the HelmRelease and pause the IAM/bucket-sync CronJobs. Wait for their
   active Jobs to finish. RustFS also serves continuous WAL, Loki and Tempo
   writes; clients may retry or buffer during the S3 outage.
3. Stop RustFS. Apply `final-sync.yaml` and require a successful exit (including
   no vanished-file exception). Run read-only checksum and metadata
   verification before starting RustFS on the SSD claim. Run `root-metadata.yaml`
   first: VolSync excludes the volume root metadata from its normal copy.
4. Verify S3 health, the bucket inventory, a pre-migration object's checksum,
   and a temporary object's write/read/delete cycle. Check fresh CNPG WAL
   archival and dependent services before restoring scheduled jobs.
5. Publish and merge the SSD configuration. Resume Flux only after the source
   contains the merged revision. Keep the original HDD data untouched.

## Rollback

Hold Flux/Helm, stop RustFS and switch the claim back to `rustfs-data-hdd`.
The original HDD volume is a pre-cutover snapshot. New S3 writes after cutover
will be absent from it; reconcile those writes before a later rollback. Never
run the old HDD-to-SSD seed against the active SSD volume.

## Initial window check

On 11 October 2026 at about 07:08 UTC no CNPG or Longhorn backup was active.
Nightly schedules had passed (CNPG 00:05–04:00 UTC; Longhorn 01:00 UTC;
Paperless VolSync 03:00 UTC). Refresh this evidence before stopping RustFS.
Authenticated baseline: 23 buckets and one existing object checksum captured
inside a temporary client Pod using native Secret references.

## Temporary staging exclusion

The seed, final copy and verification exclude only `/.rustfs.sys/tmp/` and
`lost+found`. Exact source tag `1.0.0-alpha.90` shows completed PUTs rename
from temporary staging into bucket object storage before returning. Accepted
multipart parts move into `.rustfs.sys/multipart`, which is included. Completed
multipart uploads move from there into their final bucket. All IAM, bucket,
format, object-version and system metadata remain included.

The version's startup temporary cleanup is a TODO. The first VolSync attempt
spent over 100 GB reading temporary staging, so it was paused and replaced by
the filtered rsync job. The HDD source is always read-only to the movers and
all its staging data remains untouched. Existing partial staging copies on
SSD are protected by the exclusion and have not been deleted.

Sources:
- https://github.com/rustfs/rustfs/blob/1.0.0-alpha.90/crates/ecstore/src/set_disk.rs
- https://github.com/rustfs/rustfs/blob/1.0.0-alpha.90/crates/ecstore/src/disk/local.rs

Cached S3 inventory on 11 October: 23 buckets, 118,413 objects, 256,414,673,633
logical object bytes. This excludes temporary staging and may change during
the online seed.
