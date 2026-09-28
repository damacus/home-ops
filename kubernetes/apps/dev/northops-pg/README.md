# North Ops PostgreSQL

This two-instance CloudNativePG cluster starts with one application database,
`ironbridge`, owned by the non-superuser `ironbridge` role. It can host other
North Ops databases later, each with its own role, secret and explicit database
privileges. PostgreSQL's default `PUBLIC` `CONNECT` and `TEMPORARY` privileges
are revoked for `postgres`, `template1`, and `ironbridge` at bootstrap. Revoke
the same default privileges whenever another database is added, then prove that
the IronBridge role cannot connect to it.

Before reconciliation, create a dedicated `ironbridge-db` 1Password item with
its `password` field. Create a `cnpg-northops` RustFS bucket, a dedicated IAM
credential limited to that bucket, and a `rustfs-cnpg-northops` 1Password item
with `username` and `password` fields. The existing RustFS IAM bootstrap Job
creates the bucket and the bucket-only policy from that item. The Barman Cloud plugin archives WAL
and starts a full backup immediately, then runs a daily backup at 03:10 UTC.
Its 30-day recovery window can retain deleted bridge content until obsolete
backups are removed.

Check 2/2 ready instances, successful WAL archiving and a completed backup.
Restore a backup into an isolated test cluster before enabling IronBridge.
Connect as `ironbridge` to `ironbridge`, and verify that connecting as the same
role to `postgres` and any later North Ops databases is denied. The cluster has
no database ingress; clients use `northops-pg-rw.dev.svc.cluster.local`.
