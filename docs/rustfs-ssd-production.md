# RustFS SSD production and retained HDD copy

> Historical migration procedure. HDD claim definitions and the stopped HDD
> RustFS release have now been retired from Flux. Do not follow the HDD
> retention or rollback instructions below as a current recovery procedure.
> Use the active SSD/Longhorn configuration and verified backups for recovery.
> See [HDD retirement](https://github.com/damacus/home-ops/blob/main/kubernetes/apps/storage/rustfs/HDD-RETIREMENT.md) for cleanup behaviour.

Production is the `rustfs` HelmRelease using the populated
`rustfs-dr-data-ssd` claim. The PVC name is retained to avoid replacing its data.
The console is `https://rustfs.ironstone.casa`; S3 is
`https://s3.ironstone.casa`. The previous public S3 hostname
`https://rustfs-s3.ironstone.casa` remains an alias. Cluster workloads use
`http://rustfs.storage.svc.cluster.local:9000`, preserving their original route.
Temporary DR routes remain compatibility aliases to SSD production.

The `rustfs-hdd` HelmRelease retains `rustfs-data-hdd` with **zero replicas**.
Its recovery routes are `https://rustfs-hdd.ironstone.casa` and
`https://s3-hdd.ironstone.casa`. They have no healthy backend while stopped.
This change does not delete HDD data, historical versions, PVCs or the NAS pool.
Review retention after approximately one day; there is no automatic expiry.
HDD bucket replication was disabled before stopping its original process.
Do not start an old copy with replication or application writers enabled.
Keep the HDD console origin separate from production and do not change the
production Zitadel client credentials or callback to the temporary hostname.

The former unmanaged `rustfs-dr` Deployment is stopped and still refers to the
SSD claim. After this change reconciles, remove that obsolete Deployment only;
retain its PVC and the compatibility Service/routes. Never scale it up alongside
production against the same claim.

## Acceptance

The final pre-cutover audit verified 21 source-authoritative buckets with zero
missing, extra or unresolved current objects, preserving the three buckets
already authoritative on SSD. All eleven production CNPG clusters passed fresh
backup and isolated explicit-backup-ID restore tests on 14 October 2026;
restored schemas, roles and selected application aggregates matched. Temporary
restore clusters and volumes were removed. Paperless local-data recovery,
Longhorn volume recovery, OCI push/pull, artifact storage and gateway reads,
and Loki/Tempo ingestion/query checks passed. These are storage/component tests;
they do not establish an atomic Forgejo database-and-repository backup.

Before accepting the URL transition, verify both production hostnames, original
cluster-local client access, healthy WAL archiving and no HDD workload pods.
Verify interactive OIDC sign-in separately: the original production origin is
preserved, but an additional token audience was rejected during the previous
check. Do not disable audience or TLS validation to bypass that error.
