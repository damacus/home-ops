# Paperless backup recovery

The local-data backup uses `paperless-restic-local-v2`, with repository
`volsync-paperless/localdata-v2`. It clones the active `paperless-localdata`
claim and runs daily at 03:00 UTC. The restore destination is a separate claim
and remains paused; never direct a test restore at the application claim.

## Preserved history

Do not remove either older ExternalSecret or the objects at the bucket root.
On 7 October 2026, the current key could open the repository config but could
not decrypt any of nine snapshot objects or either index. Selecting its older
key could not decrypt the config. This is consistent with mixed encryption
history, but the original copying or replacement event has not been established.
Do not run destructive repair or pruning against that history. A shared password
does not make independently initialised restic repositories interchangeable.

## Coverage and verification

This VolSync source protects local SQLite/application data. Document media and
pending intake are on the Paperless NFS mount and are outside this source.
It is not a complete application backup by itself.

On 7 October, the replacement local repository passed `check --read-data` and
a restore with file verification. The restored SQLite database passed
`integrity_check` and contained 332 documents.

A separate, manually captured application export was stored at
`volsync-paperless/exports-v1`, snapshot `5f611676`. It contains the complete
export, pending intake and a checksum catalogue. The repository passed a full
data read. An isolated restore verified every exported file hash, imported all
332 documents, passed SQLite integrity checking and completed Paperless's sanity
checker without errors (three informational no-OCR notices). This one-off capture
does not establish a recurring full-export
schedule or an independent storage destination. RustFS and the document media
still share the primary NAS failure domain; the DSM pull plan remains separate.

To create a consistent export, stop all Paperless application writers, retain
the deployment replica count, copy the stopped SQLite directory including its
journals into private writable scratch space, then export using the deployed
image and unchanged document media. Django's SQLite initialisation cannot use a
read-only data directory directly. Include pending intake, detect concurrent
intake changes, record checksums and document count, and resume the application
even if capture fails. Encrypt the completed capture and restore it into an
isolated application with its own SQLite/media storage and Redis. Create the
normal data/index directory before import; do not connect the restore instance
to production integrations.

## Operational checks

Check ReplicationSource `lastSyncTime` and `latestMoverStatus`, the mover logs,
repository integrity and a restore. A green Job or a timestamp alone is not
proof of recoverability. Keep full-export freshness distinct from local-data
freshness. After changing the repository, verify the actual mover uses the new
secret and preserve existing source and restore claims.

Use normal restic snapshot retention only in the clean repository after its
restore checks pass. Do not mirror separately initialised repositories at the
object level; use restic's supported copy operation when both are readable.
