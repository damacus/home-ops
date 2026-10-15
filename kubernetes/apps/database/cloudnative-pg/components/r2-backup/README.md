# Nightly standalone PostgreSQL backups to R2

Each production database has a separate nightly physical-backup CronJob. Its
existing CNPG/Barman base backups, continuous WAL archive and thirty-day local
retention remain unchanged. The R2 job uses the existing streaming-replica
certificate, verifies the server certificate, and includes the WAL generated
during capture with `pg_basebackup --wal-method=stream`.

`pg_verifybackup` must succeed before upload. The archive is downloaded again
using retryable multipart transfers and its SHA-256 compared before publishing
`manifest.json`. The manifest is the completion marker. Only completed
generations older than seven days under that database's prefix can expire.
Incomplete generations and unrelated objects are never pruned by this job.
This gives nightly recovery points, not continuous off-site point-in-time
recovery. A full site loss can lose changes since the last successful job.

Schedules are staggered and each job forbids overlap. Temporary node storage is
sized per database; it contains the verified base, compressed archive and
verification download. No NAS volume is mounted. Credentials come from the
owner's existing R2 item through a dedicated ExternalSecret per database.
The R2 Standard bucket is `cnpg`; the prefix is isolated per database.

## Recovery

1. Select a completed generation by its `manifest.json`. Obtain its named
   archive from R2 using the independent R2 credentials, not the local RustFS
   service. Match the archive SHA-256 against the manifest before extraction.
2. Extract into empty disposable storage with safe tar extraction. The archive
   contains a `data` directory. Run PostgreSQL 18 `pg_verifybackup` against it.
3. Set the data-directory mode to 0700. Safe Python tar extraction intentionally
   does not restore directory modes, so this step is required.
4. For the isolated validation instance, use the matching source PostgreSQL
   image, a fresh minimal configuration and local socket authentication. Clear
   `postgresql.auto.conf` and remove recovery/standby signal files only in this
   restored copy after verification. Disable archiving and external listeners;
   never connect the recovered instance to production replication or services.
5. Start PostgreSQL. Require successful end-of-backup WAL replay, readiness and
   `pg_is_in_recovery() = false`. Compare database schemas and roles, then check
   the application's expected data. Keep a NetworkPolicy denying ingress.
6. Remove disposable restore pods after acceptance. For a real recovery, build
   the replacement CNPG deployment and reconnect its application deliberately;
   this archive is a standalone physical backup, not a Barman backup catalogue.

The n8n pilot restored 137 tables, 12 workflows and six credential records using
only the R2 archive and its included WAL. No database content or credentials
belong in logs or Git.

## Why a separate CronJob

A separate CNPG ScheduledBackup with an `objectStore` parameter was tested.
The running Barman sidecar 0.6.0 ignored it and wrote into the Cluster's normal
RustFS store. The trial schedule remains suspended. The tagged implementations
for 0.6.0 and 0.15.1 both derive the backup write destination from the Cluster.
The dedicated job therefore avoids altering working local backup/WAL routing.
