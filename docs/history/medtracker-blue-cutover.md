---
doc_type: history
description: Earlier destructive blue-to-canonical cutover procedure and recovery constraints.
---

# MedTracker blue cutover procedure

Historical procedure from the consolidation. Its database reset was specific
to that work and must not be repeated as maintenance. This archived text is
not evidence of current deployment health or renewed approval to discard data.
Use the [current database guide](../../kubernetes/apps/home/med-tracker-db/README.md) first.

## Original procedure


The HelmRelease and `operations/setup-job.yaml` use the same immutable 0.6.5
image, which supports the PostgreSQL connection fields supplied by CNPG Secrets.

This procedure discards all live MedTracker data and accounts, as approved by
the owner. It retains the original cluster, volumes and backup archive. Run it
through the delivery controller during a maintenance window, using explicit
`--context ironstone` on every Kubernetes command. Do not recreate the cluster
or its volumes. No additional production app or database is needed.

1. Before merging the consolidation, suspend the `med-tracker` Flux Kustomization
   and HelmRelease. Scale the existing web, worker and scheduler Deployments to
   zero and wait until their Pods have terminated. Keep them stopped until
   installation succeeds; otherwise queued jobs could write to the old database.
   Keep the existing Helm release and `med-tracker-app` ServiceAccount: the
   migration hook uses that retained ServiceAccount before upgrading the release.
2. Populate the canonical 1Password fields above. Disable automatic retention on
   `med-tracker-rustfs-store` before resetting anything, and confirm the retained
   backup and WAL. Leave the original backup credentials unchanged.
3. Merge the consolidation through the delivery controller. Reconcile
   `med-tracker-db` and wait for its ExternalSecrets to be Ready. Before setup,
   wait for every role declared in `cluster.yaml` to appear in
   `status.managedRolesStatus.byStatus.reconciled` on the `med-tracker` Cluster,
   with no entries in `status.managedRolesStatus.cannotReconcile`. The application
   HelmRelease in Git is deliberately suspended. The removed blue Kustomization
   may prune its Secrets and backup schedule; its Cluster has pruning disabled
   and must be deleted explicitly only after the replacement works.
4. Pause `med-tracker-db` reconciliation. Remove the `med-tracker-app` Database
   resource temporarily, leaving its PostgreSQL database retained. Confirm the old
   `med-tracker-cache`,
   `med-tracker-queue` and `med-tracker-cable` Database resources have been pruned.
   Removing the old Database resources does not drop their PostgreSQL databases:
   CNPG's default reclaim policy is `retain`.
5. Open an administrator `psql` session to the **current primary** of cluster
   `med-tracker`, connected to maintenance database `postgres`. Use local peer
   authentication in the database Pod; do not print or pass passwords in command
   arguments. Set `ON_ERROR_STOP` and check `pg_database` before executing:

   ```sql
   DROP DATABASE "med-tracker" WITH (FORCE);
   DROP DATABASE IF EXISTS medtracker_production_cache WITH (FORCE);
   DROP DATABASE IF EXISTS medtracker_production_queue WITH (FORCE);
   DROP DATABASE IF EXISTS medtracker_production_cable WITH (FORCE);
   CREATE DATABASE "med-tracker" OWNER "med-tracker";
   ```

   This is explicit operator database administration, not an application
   migration or an automatic Helm hook. Run no destructive Loco migration
   commands. If any statement fails, stop and inspect the database state.
6. Apply `operations/setup-job.yaml` once and wait for successful completion.
   It runs the released native `database-setup` task against the empty database,
   installing the schema and restricted logins. Inspect its result; do not
   repeatedly delete and rerun a failed Job without diagnosing the failure.
7. Resume `med-tracker-db` reconciliation and wait for the managed Database to
   report Ready. After setup succeeds, remove `spec.suspend: true` from the
   application HelmRelease through the delivery controller. Resume the app Flux
   Kustomization and HelmRelease. The existing release's migration Job, web,
   worker and scheduler must all use the same immutable 0.6.5 image.
8. Verify startup, sign-up/sign-in, household creation, queue processing and
   scheduler operation, and allowed and denied database access. Confirm the
   Service and both existing hostnames route to the replacement. Confirm a new
   database backup and continuous WAL archiving succeed. HTTP readiness alone
   does not establish acceptance.
9. Delete the unused `med-tracker-blue` Cluster explicitly, then inspect and
   remove only its PVCs if they remain. Never select the retained `med-tracker`
   PVCs. Remove orphaned blue Kubernetes Secrets and the completed setup Job.
   Keep the original backup until the owner accepts the replacement; backup
   removal is a separate decision.

After the reset, rollback means recovering the retained original backup. There
is no supported way to run Rails against the Rust schema, and restoring the old
backup does not preserve data written by the replacement.
