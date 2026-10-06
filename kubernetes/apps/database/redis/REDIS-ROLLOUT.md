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

## Required cutover gates

Do not merge or reconcile the final authentication change until credentials
and the data migration are ready. Redis currently uses `emptyDir`; replacing
that pod loses its append-only log. Helm rollback does not restore those bytes.

1. Create the `redis-auth` item in the home-ops vault. Validate all four
   credentials without printing them. Ensure each application's ExternalSecret
   exposes only its own credential, and that the admin/ACL Secret stays in
   `database`.
2. Merge and deploy prerequisite PR #4432, which delivers the new PVC and ExternalSecrets,
   leaving the running Redis and application configuration unchanged. Verify
   the Secrets are Ready and `redis-data` is available. With WaitForFirstConsumer
   storage, provision it through the migration helper rather than waiting for
   an unmounted PVC to bind.
3. Schedule a short maintenance window. Pause incoming n8n workflows, Paperless
   ingestion and Penpot writes; allow workers to finish. Record the replicas
   and queue state. Do not assume an empty queue from an empty Redis key list.
4. Preserve a bounded, verified snapshot of the old Redis while writes are
   quiesced. Use Redis replication/RDB export (`redis-cli --rdb`) to obtain a
   consistent snapshot. Store an independent rollback copy securely. Seed
   `redis-data` with `dump.rdb`, owned/readable by UID/GID 1001. The helper must
   use a narrowly allowed migration identity in the Redis ingress policy; do
   not disable the policy or impersonate an application pod.
5. Restore the snapshot in an isolated instance with this image, ACL and
   configuration. Compare database key counts and representative queue state;
   confirm AOF begins from the restored snapshot. Keep the old Redis pod and
   rollback copy until this succeeds.
6. Merge the final PR and reconcile Redis through Flux. The explicit
   `existingClaim` keeps the data independent of the Helm release and avoids
   adding immutable StatefulSet volume claim templates. Restart clients with
   their new Secret references and restore their recorded replicas.
7. Verify anonymous and wrong-password connections fail. Confirm named client
   users, no ACL errors, Paperless ingestion, a harmless n8n execution through
   its worker, and Penpot editing/export. Confirm new queue work survives a
   controlled Redis replacement. Inspect Cilium flows: Penpot's exporter is a
   real Redis client and needs its own permitted ingress path.

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
