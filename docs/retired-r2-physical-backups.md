# Retired standalone R2 database backups

The custom nightly physical-backup CronJobs were removed on 19 October 2026.
They are not the permanent off-site backup design. New off-site database
recovery points are not produced by these jobs, and their automatic seven-day
retention has stopped. Existing R2 objects and credentials are preserved.
Local CNPG/Barman backups, continuous WAL archiving and Longhorn backups remain
configured separately.

Native per-backup ObjectStore selection is tracked upstream in
[plugin-barman-cloud PR #1076](https://github.com/cloudnative-pg/plugin-barman-cloud/pull/1076).
A release containing that change must also be assessed for independent WAL
availability before off-site recovery is considered complete. The intended
retention remains 30 days locally and seven days off-site once a supported
replacement is approved and tested.

## Recover an existing standalone generation

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
