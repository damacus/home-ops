# MedTracker database

`med-tracker-db` owns the existing PostgreSQL 18 cluster named `med-tracker`,
its credentials, monitoring and backups. MedTracker uses one database,
`med-tracker`, for application records and its PostgreSQL background queue.
The former Rails cache, queue and cable databases are retired.

Runtime uses `med_tracker_runtime`; upgrades use `med_tracker_update`.
The existing `med-tracker` database owner has login disabled. Only the manually
run installation Job receives the PostgreSQL administrator credential. Normal
Helm upgrades run `db migrate` with the restricted update credential.
CloudNativePG manages both login passwords from their respective Secrets;
neither login has PostgreSQL's `SUPERUSER` or `BYPASSRLS` attributes. The update
login inherits table ownership and can alter or disable row-level security;
treat it as a privileged schema-maintenance credential.

CNPG's generated `med-tracker-app` Secret supplies `host`, `port` and `dbname`.
Each process reads `username` and `password` from its own credential Secret using
the standard PostgreSQL environment fields. The generated owner password is not
given to the application. No connection URLs are constructed in HomeOps.

The application, administrator and retained credentials below come from the
existing `med-tracker-db` 1Password item:

| Field | Use |
| --- | --- |
| `password` | Retained original login credential for backup recovery |
| `superuser_password` | Existing cluster administrator; keep unchanged |
| `runtime_password` | Restricted runtime login |
| `update_password` | Restricted migration login |
| `AUTH_SESSION_SECRET` | Application signing secret |
| `MEDTRACKER_SESSION_KEY` | Browser session key |

Populate the four Rust fields from the existing blue credential item through
1Password, without printing values or storing them in Git. Retain the blue item
until cutover succeeds. Integration credentials remain in their existing items.

## Retained backup

The original archive stays at `s3://cnpg-med-tracker/`, server name `med-tracker`,
using the existing RustFS credentials. `ObjectStore.spec.retentionPolicy` is
deliberately omitted so the plugin does not expire the original backup while
acceptance is outstanding. Do not restore the former `30d` policy or delete
backup objects, the archive, or its credentials until the owner accepts the
replacement. Continue daily backups and WAL archiving on the same cluster.

Before any reset, confirm a recent completed backup, its backup ID and its
required WAL are present in the archive. A completed Kubernetes Backup resource
alone does not prove restoreability. Check any bucket-level lifecycle separately.
Keep that recovery information with the retained backup, outside Git if sensitive.

## Maintenance and recovery

Use the released migration workflow and the restricted update credential for
schema changes. Do not reset the database as an upgrade step. The
[earlier blue cutover](../../../../docs/history/medtracker-blue-cutover.md)
contains destructive one-time instructions, retained for context only.

Recover into an isolated replacement from the retained backup and its required
WAL before reconnecting the application. Verify expected application records,
roles, queue processing and allowed/denied access. Restoring an older backup
discards writes after that recovery point. HTTP readiness alone does not prove
application or backup acceptance.
