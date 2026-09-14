# Paperless data restore

Paperless stores its SQLite database, search index, and classifier data on the
`paperless-localdata` Longhorn claim. VolSync backs up a point-in-time clone of
that claim to the `rustfs-paperless` repository.

The `paperless-localdata-restore` ReplicationDestination is paused during normal
operation. This prevents Flux from starting a restore before a usable backup
exists.

## Restore the latest backup

1. Confirm that `paperless-local-backup` has a successful mover result that does
   not report an empty directory.
2. Through Flux, set `spec.paused` to `false` on
   `paperless-localdata-restore` and change `spec.trigger.manual` to a new unique
   value.
3. Wait for the ReplicationDestination mover result to report success.
4. Through Flux, change both of these claims to `paperless-localdata-restore`:
   - `persistence.data.existingClaim` in `app/helmrelease.yaml`
   - `spec.sourcePVC` in `app/volsync/replicationsource.yaml`
5. Reconcile Paperless and verify the system check, login, document search, and
   document consumption.

Keep the original claim until the recovered application and a new backup are
verified.
