# Redis authentication and durable queues

This change keeps the shared Redis endpoint and logical database numbers. It
uses separate Paperless, n8n and Penpot credentials, and an administrator
credential for probes and maintenance. ExternalSecrets reads the `redis-auth`
1Password item: `admin_password`, `paperless_password`, `n8n_password`, and
`penpot_password`. Generate unique URL-safe random passwords with at least
32 bytes of entropy. Do not put passwords in Git, command arguments or logs.

Application users can operate queues, transactions, Lua scripts and pub/sub.
They cannot manage ACLs, change server configuration, load modules, shut down
Redis or flush databases. Key and channel access remains shared: these ACLs
provide authentication and command restrictions, not isolation between apps.
Do not claim that numbered Redis databases provide a security boundary.

The image is pinned to the multi-architecture digest of the currently deployed
Redis 8.4.0. The chart is pinned to 28.2.0. Runtime configuration sets 32 MiB
`maxmemory` with `noeviction`; the container has a 128 MiB limit to leave room
for allocator overhead and persistence. Queued work must never be silently
evicted. Watch memory use and rejected writes before lowering either limit.
The unused search/JSON modules are not loaded by this queue configuration.

## Approved fresh-volume cutover

The owner has explicitly chosen a fresh Redis start and declined migration of
existing queue/cache contents. The old Redis `emptyDir` is disposable for this
cutover. Replacing the pod discards those contents. The unused export helper
remains available for a future migration but must not be activated here.

1. Create and verify the four credentials in the home-ops 1Password vault.
2. Deploy prerequisite PR #4432 and verify all four ExternalSecrets are Ready
   and `redis-data` is Bound. These prerequisites leave running clients unchanged.
3. Record client replicas. Pause client reconciliation during the approved
   maintenance window and stop Redis clients before enabling authentication.
4. Deploy this PR through Flux, starting Redis on the fresh protected PVC.
   Reconcile client Secret references and restore their recorded replicas.
5. Verify anonymous and wrong-password connections fail, named clients connect,
   and Redis ACL logs contain no denied application commands. Confirm Paperless,
   n8n main/worker and Penpot backend/exporter are Ready.
6. Write a harmless temporary acceptance marker and verify it survives a
   controlled Redis replacement. Confirm the live Reloader-triggered rollout.
   Application-level ingestion, workflow execution and editing/export remain
   acceptance checks and must be reported explicitly if not exercised.

## Rollback

Pause producers before a rollback. Preserve the current PVC and its AOF; its
`prune: disabled` annotation prevents Flux from deleting the data volume.
Revert client/authentication changes through Git. Retain the durable mount,
image pin and data, unless a separately verified restore is necessary. Do not
blindly revert to the old `emptyDir` configuration. Never restore an old
snapshot over newer queued work without an explicit data-loss decision.

Redis remains a cluster-only TCP service. This change does not add TLS.

## Credential rotation

The Redis StatefulSet watches `redis-auth` through its Reloader workload
annotation. Changing its ACL Secret triggers a Redis rollout, so the new
password hashes are loaded. Clients also restart when their own Secrets change.
These independent reconciliations can briefly overlap; clients must retry while
the single Redis pod restarts. For planned rotation, use a maintenance window
and verify both new-password acceptance and old-password rejection after all
Secrets and workloads converge. A live Reloader-triggered rollout remains a
post-deployment acceptance check; the isolated test verifies the rendered
trigger and password behaviour after replacement.
