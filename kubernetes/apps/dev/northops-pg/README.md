# North Ops PostgreSQL

This two-instance CloudNativePG cluster starts with one application database,
`ironbridge`, owned by the non-superuser `ironbridge` role. It can host other
North Ops databases later, each with its own role, secret and explicit database
privileges. PostgreSQL's default `PUBLIC` `CONNECT` and `TEMPORARY` privileges
are revoked for `postgres`, `template1`, and `ironbridge` at bootstrap. Revoke
the same default privileges whenever another database is added, then prove that
the IronBridge role cannot connect to it.

Before reconciliation, create a dedicated `ironbridge-db` 1Password item with
its `password` field. Create a `cnpg-northops` RustFS bucket and a dedicated
`rustfs-cnpg-northops-v1` 1Password item with `username` and `password` fields.
The separate `rustfs-iam-northops` Flux Kustomization provisions a bucket-only
IAM identity from that item. Other RustFS IAM consumers do not depend on these
new credentials. The Barman Cloud plugin archives WAL
and starts a full backup immediately, then runs a daily backup at 03:10 UTC.
Its 30-day recovery window can retain deleted bridge content until obsolete
backups are removed.

Check 2/2 ready instances, successful WAL archiving and a completed backup.
Restore a backup into an isolated test cluster before enabling IronBridge.
Connect as `ironbridge` to `ironbridge`, and verify that connecting as the same
role to `postgres` and any later North Ops databases is denied. The cluster has
no database ingress; clients use `northops-pg-rw.dev.svc.cluster.local`.

Rotate the RustFS backup key in stages. Never edit a versioned 1Password item
in place: both the IAM bootstrap Job and the database backup Secret refer to
the same version, but the Job does not rerun when the item changes. Create a
`rustfs-cnpg-northops-v2` item and add a second ExternalSecret and bootstrap
Job under `rustfs-iam/northops` with v2 names. Wait for that Job to succeed and
verify the new key can access only `cnpg-northops`. Then change the database
backup ExternalSecret to read v2, verify WAL archiving and a new backup, and
perform an isolated restore. Retain v1 for rollback until those checks pass.
