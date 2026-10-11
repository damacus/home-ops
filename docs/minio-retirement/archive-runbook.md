# Archive bundled OpenEBS MinIO into RustFS

This is a manual Stage 2 procedure. Merging this runbook does not run it.
Obtain approval for Stage 2 before changing the live cluster. Pause at the end.
Do not use `task kubernetes:object-storage-migrate`: that helper targets the
retired standalone MinIO endpoint, not this bundled instance.

## Prerequisites and recovery

Use Bash with `set -euo pipefail` and `umask 077`. Required tools: Flux, kubectl,
MinIO `mc`, rclone, jq, curl and diff. Use the explicit `ironstone` context.
Move the private Stage 1 rollback directory from `/private/tmp` to durable,
private storage first. Keep an independent copy; it contains credentials.
Save the original Alloy DaemonSet as well before altering it.

```bash
export ARCHIVE_RUN_DIR="$(mktemp -d)/openebs-minio-archive"
mkdir -m 700 "$ARCHIVE_RUN_DIR"
kubectl --context ironstone -n openebs-system get ds openebs-alloy -o json > "$ARCHIVE_RUN_DIR/alloy-before.json"
kubectl --context ironstone -n openebs-system get cm loki -o json > "$ARCHIVE_RUN_DIR/loki-config.json"
kubectl --context ironstone -n monitoring get helmrelease loki
kubectl --context ironstone -n openebs-system get sts openebs-loki openebs-minio
```

Before proceeding, verify central Loki is Ready and ingests recent logs, all six
source PVs still use Retain, all six claims are Bound and neither source
StatefulSet deletes claims on scaling or deletion. RustFS must be healthy and
have enough free space. Do not stop RustFS or combine this with its SSD cutover.

## Private buckets and restricted identities

Configure administrator `mc` aliases named `source-admin` and `archive-admin`
using private credential handling. Source is the bundled service, reached with
port forwarding below; archive is RustFS. Never use `s3.ironstone.casa` here.
Run these in separate terminals and keep them alive throughout the operation:

```bash
kubectl --context ironstone -n openebs-system port-forward svc/openebs-minio 19000:9000
```

```bash
kubectl --context ironstone -n storage port-forward svc/rustfs 19001:9000
```

Source endpoint: `http://127.0.0.1:19000`. Archive endpoint:
`http://127.0.0.1:19001`. Load fresh, randomly generated migration credentials
into `ARCHIVE_SOURCE_ACCESS_KEY`, `ARCHIVE_SOURCE_SECRET_KEY`,
`ARCHIVE_TARGET_ACCESS_KEY`, `ARCHIVE_TARGET_SECRET_KEY` without echoing them.
Keep them private; do not use either service's root credentials for copying.

```bash
for bucket in chunks ruler admin manifests; do
  mc mb --ignore-existing "archive-admin/openebs-loki-archive-$bucket"
  mc anonymous set none "archive-admin/openebs-loki-archive-$bucket"
  mc anonymous get-json "archive-admin/openebs-loki-archive-$bucket" > "$ARCHIVE_RUN_DIR/$bucket-anonymous.json"
  mc ilm rule ls --json "archive-admin/openebs-loki-archive-$bucket" > "$ARCHIVE_RUN_DIR/$bucket-lifecycle.json"
done
mc admin policy create source-admin openebs-loki-archive-read docs/minio-retirement/source-read-policy.json
mc admin user add source-admin "$ARCHIVE_SOURCE_ACCESS_KEY" "$ARCHIVE_SOURCE_SECRET_KEY"
mc admin policy attach source-admin openebs-loki-archive-read --user "$ARCHIVE_SOURCE_ACCESS_KEY"
mc admin policy create archive-admin openebs-loki-archive-write docs/minio-retirement/archive-write-policy.json
mc admin user add archive-admin "$ARCHIVE_TARGET_ACCESS_KEY" "$ARCHIVE_TARGET_SECRET_KEY"
mc admin policy attach archive-admin openebs-loki-archive-write --user "$ARCHIVE_TARGET_ACCESS_KEY"
mc alias set source http://127.0.0.1:19000 "$ARCHIVE_SOURCE_ACCESS_KEY" "$ARCHIVE_SOURCE_SECRET_KEY"
mc alias set archive http://127.0.0.1:19001 "$ARCHIVE_TARGET_ACCESS_KEY" "$ARCHIVE_TARGET_SECRET_KEY"
```

Review the saved bucket policies and lifecycle rules: no anonymous access and no
expiration rules. If an archive bucket already contains objects, stop and
investigate before using it. The policies grant no object deletion, bucket
creation, policy editing or access to central Loki's live buckets. Verify the
new identities have only their named policy and no group membership. Check an
anonymous object request is denied, source PutObject is denied, and archive
access to `loki-chunks` is denied before copying. Use harmless temporary fixture
keys for denied-write checks; stop if one unexpectedly succeeds.

## Quiesce the bundled writers

Suspend both reconciliation layers so Helm or Flux cannot restart writers.
Confirm no node has the pause label before patching Alloy. Vector remains live.

```bash
flux --context ironstone suspend kustomization openebs -n flux-system
flux --context ironstone suspend helmrelease openebs -n openebs-system
kubectl --context ironstone get nodes -l minio-retirement=paused
kubectl --context ironstone -n openebs-system patch ds openebs-alloy --type=merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"minio-retirement":"paused"}}}}}'
kubectl --context ironstone -n openebs-system get ds openebs-alloy
kubectl --context ironstone -n openebs-system get pods -l app.kubernetes.io/name=alloy
```

Wait until Alloy has zero desired/current pods and its old pods are gone. Check
central Loki still receives logs. Flush **each** bundled Loki ingester through a
pod-specific port forward, never the load-balanced Service. For each ordinal
0, 1 and 2, run the following with the correct pod name, then use the next block:

```bash
kubectl --context ironstone -n openebs-system port-forward pod/openebs-loki-0 13100:3100
```

```bash
curl --fail --show-error --max-time 600 -X POST http://127.0.0.1:13100/flush
curl --fail --show-error http://127.0.0.1:13100/metrics > "$ARCHIVE_RUN_DIR/loki-0-flush-metrics.txt"
```

`/flush` returning does not by itself prove every write has finished. Observe
`loki_ingester_flush_queue_length` reach zero on each pod, check no flush errors,
and use `/ingester/shutdown?flush=true&terminate=false` on each ingester to flush
and shut down the ingester service before scaling. Do not set `flush=false`.
Capture each successful response and pod logs privately. If a flush fails,
stop: retain the WAL and recover the ingester before archiving.

```bash
curl --fail --show-error --max-time 600 -X POST 'http://127.0.0.1:13100/ingester/shutdown?flush=true&terminate=false'
```

After all three ingesters have completed shutdown, scale bundled Loki to zero:

```bash
kubectl --context ironstone -n openebs-system scale sts openebs-loki --replicas=0
kubectl --context ironstone -n openebs-system get pods,sts
```

Verify no bundled Loki or Alloy pod remains, MinIO still has three ready pods,
and central Loki is healthy. Save final MinIO inventories twice, a minute apart,
and compare them to confirm compaction or other writes have stopped. The
rollback procedure is at the end; do not leave the reconciliation pause implicit.

## Capture versions and copy live objects

```bash
for bucket in chunks ruler admin; do
  mc version info "source/$bucket" > "$ARCHIVE_RUN_DIR/$bucket-versioning.txt"
  mc ls --recursive --versions --json "source/$bucket" > "$ARCHIVE_RUN_DIR/$bucket-versions.jsonl"
  jq --slurp --exit-status 'all(.[]; .status == "success" and .versionId == "null")' "$ARCHIVE_RUN_DIR/$bucket-versions.jsonl"
done
```

The previous inventory had null versions and deletion markers only. If the
check finds non-null versions, stop and extend the archive to retain every
historical payload; a live-object copy alone is then insufficient. Preserve the
JSONL inventories: they contain original S3 LastModified timestamps, delete
markers and keys. Do not recreate deletion markers in the archive or mix the
archive with the live Loki buckets.

Configure rclone through environment variables, avoiding credential command
arguments or a committed config file. Disable automatic region detection and
bucket checks so the restricted identities need no bucket-admin permissions.

```bash
export RCLONE_CONFIG_SOURCE_TYPE=s3 RCLONE_CONFIG_SOURCE_PROVIDER=Minio
export RCLONE_CONFIG_SOURCE_ENDPOINT=http://127.0.0.1:19000
export RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID="$ARCHIVE_SOURCE_ACCESS_KEY"
export RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY="$ARCHIVE_SOURCE_SECRET_KEY"
export RCLONE_CONFIG_ARCHIVE_TYPE=s3 RCLONE_CONFIG_ARCHIVE_PROVIDER=Minio
export RCLONE_CONFIG_ARCHIVE_ENDPOINT=http://127.0.0.1:19001
export RCLONE_CONFIG_ARCHIVE_ACCESS_KEY_ID="$ARCHIVE_TARGET_ACCESS_KEY"
export RCLONE_CONFIG_ARCHIVE_SECRET_ACCESS_KEY="$ARCHIVE_TARGET_SECRET_KEY"
export RCLONE_CONFIG_SOURCE_REGION=us-east-1 RCLONE_CONFIG_ARCHIVE_REGION=us-east-1
for bucket in chunks ruler admin; do
  rclone lsjson "source:$bucket" --recursive --files-only --metadata > "$ARCHIVE_RUN_DIR/$bucket-source-before.json"
  rclone copy "source:$bucket" "archive:openebs-loki-archive-$bucket" --metadata --s3-no-check-bucket --checkers 4 --transfers 4
 done
```

Copy only; never use sync, purge or delete. Rclone preserves supported S3 headers
and user metadata with `--metadata`; S3 assigns a new LastModified timestamp on
upload, so original timestamps remain in the source inventories. ETags are not
SHA256 and are not accepted as proof of identical data.

## Two independent verification passes

Run this complete block twice. Each pass lists both ends, checks exact keys,
bytes, MIME types and writable metadata, then downloads every live object from
both endpoints to compute SHA256. No sampling or one-way comparison is allowed.
Only S3 upload time (`btime`) is excluded from metadata equality. If any other
field differs, stop and investigate; do not relax the comparison silently.

```bash
for pass in 1 2; do
  for bucket in chunks ruler admin; do
    stem="$ARCHIVE_RUN_DIR/$bucket-pass-$pass"
    rclone lsjson "source:$bucket" --recursive --files-only --metadata > "$stem-source.json"
    rclone lsjson "archive:openebs-loki-archive-$bucket" --recursive --files-only --metadata > "$stem-archive.json"
    for side in source archive; do
      jq --sort-keys 'sort_by(.Path) | map({Path,Size,MimeType,Metadata:((.Metadata // {}) | del(.btime))})' "$stem-$side.json" > "$stem-$side-canonical.json"
    done
    diff -u "$stem-source-canonical.json" "$stem-archive-canonical.json"
    rclone hashsum SHA256 "source:$bucket" --download --output-file "$stem-source.sha256"
    rclone hashsum SHA256 "archive:openebs-loki-archive-$bucket" --download --output-file "$stem-archive.sha256"
    LC_ALL=C sort "$stem-source.sha256" > "$stem-source-sorted.sha256"
    LC_ALL=C sort "$stem-archive.sha256" > "$stem-archive-sorted.sha256"
    diff -u "$stem-source-sorted.sha256" "$stem-archive-sorted.sha256"
    if [ "$pass" = 2 ]; then
      diff -u "$ARCHIVE_RUN_DIR/$bucket-pass-1-source-canonical.json" "$stem-source-canonical.json"
      diff -u "$ARCHIVE_RUN_DIR/$bucket-pass-1-source-sorted.sha256" "$stem-source-sorted.sha256"
    fi
    jq '{objects:length,bytes:(map(.Size)|add // 0)}' "$stem-source.json" > "$stem-summary.json"
  done
 done
for bucket in chunks ruler admin; do
  mc ls --recursive --versions --json "source/$bucket" > "$ARCHIVE_RUN_DIR/$bucket-versions-after.jsonl"
  diff -u "$ARCHIVE_RUN_DIR/$bucket-versions.jsonl" "$ARCHIVE_RUN_DIR/$bucket-versions-after.jsonl"
done
rclone copy "$ARCHIVE_RUN_DIR" archive:openebs-loki-archive-manifests --metadata --s3-no-check-bucket
rclone check "$ARCHIVE_RUN_DIR" archive:openebs-loki-archive-manifests --download
```

Retain a second private copy of the run directory outside RustFS. It contains
historical log metadata; restrict access. Revoke migration users after acceptance,
keeping bucket privacy and retained data. Do not upload credentials or Stage 1
Secret snapshots into the manifests bucket.

Pause here. Record counts, bytes, both hash comparisons, unchanged source version
inventories, private bucket checks and central logging health. Do not merge the
service-removal PR until the owner accepts this evidence. If keeping the archive
for later query, preserve the original Loki schema, tenant `openebs` and ruler
configuration; do not point central Loki at these buckets.

## Abort and rollback

Keep MinIO and all six retained claims. Restore the original Alloy nodeSelector
from the private DaemonSet snapshot; scale `openebs-loki` back to three replicas.
Resume the OpenEBS HelmRelease and Kustomization only while Git still enables
the bundled services. Confirm all three Loki ingesters and Alloy agents recover.
Keep the archive buckets for investigation; do not delete partial archives or
source data automatically. On successful Stage 2, leave both reconciliation
layers suspended and record that state until the approved Stage 3 rollout.
