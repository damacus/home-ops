# OpenEBS logging retirement

> Historical migration procedure. HDD claim definitions and the stopped HDD
> RustFS release have now been retired from Flux. Do not follow the HDD
> retention or rollback instructions below as a current recovery procedure.
> Use the active SSD/Longhorn configuration and verified backups for recovery.
> See [HDD retirement](https://github.com/damacus/home-ops/blob/main/kubernetes/apps/storage/rustfs/HDD-RETIREMENT.md) for cleanup behaviour.

The OpenEBS 4.6.2 chart includes a second Loki, Alloy and MinIO stack.
Keep OpenEBS Hostpath and application volumes. Central Loki in `monitoring`
uses RustFS and will remain the live logging backend.

## Stage 1: protect the source and repair central logging

Before disabling bundled services, set the six source PV reclaim policies to
`Retain` and both `openebs-loki` and `openebs-minio` StatefulSet claim retention
policies to `Retain` for deletion and scaling. OpenEBS values disable
`loki.singleBinary.persistence.enableStatefulSetAutoDeletePVC` so Helm does not
restore the bundled Loki deletion policy. The MinIO chart already retains claims.

| Claim in openebs-system | Persistent volume | Node |
| --- | --- | --- |
| storage-openebs-loki-0 | pvc-bda470c0-2036-47bd-bcd0-b0f8bd9681fb | node-0b06a7 |
| storage-openebs-loki-1 | pvc-77dc87b1-c5b2-4bcb-8d52-f90a247d107d | node-0b06df |
| storage-openebs-loki-2 | pvc-493915bb-b474-4437-a67b-8670d847e6c0 | node-0b0715 |
| export-openebs-minio-0 | pvc-84911334-3c5c-4b3d-a30f-077c4d8084ff | node-0b0715 |
| export-openebs-minio-1 | pvc-eae266b4-2b91-4664-a8b6-97e2ecd9c7a9 | node-0b06df |
| export-openebs-minio-2 | pvc-6522a5a0-3e54-4732-8a69-29ab5c085402 | node-0b06a7 |

Central Loki previously rolled back because the ClusterRoleBinding roleRef is
immutable. Suspend its HelmRelease, replace only `loki-clusterrolebinding` with
the existing `loki-rule-configmaps` role, preserve Helm ownership, then resume
and reconcile with `--reset`. Do not force replacement of the whole release.
Verify the release is Ready, recent and historical queries work, the three alert
rules evaluate, and the Loki service account can read ConfigMaps but not Secrets.

Private pre-change snapshots of the source PVs, PVCs, StatefulSets, HelmRelease,
Loki configuration, MinIO credential Secret and central Loki binding were saved
on the operator machine under `/private/tmp/minio-retirement-stage1-20261011`
with directory mode 0700 and file modes 0600. They contain credentials: do not
commit them. This is a local rollback snapshot, not an independent data backup.
Move it to durable private storage before removing the source credential Secret.
Keep all six PVs retained during rollback; never restore their Delete policies.
The original chart values and source configurations allow the bundled services
to be restored against the retained claims if a later stage needs rollback.

## Stage 2: archive historical objects (separate approval)

Use the [manual archive runbook](minio-retirement/archive-runbook.md). Its IAM
policies and commands are inert until an operator starts the approved stage.

Create private RustFS buckets `openebs-loki-archive-chunks`,
`openebs-loki-archive-ruler`, `openebs-loki-archive-admin` and
`openebs-loki-archive-manifests`. Use restricted migration credentials and no
expiry. Disable bundled Alloy, flush all three bundled Loki ingesters, verify
persistence, then stop bundled Loki while keeping MinIO available.

Copy live objects through the S3 API, preserving keys and metadata. Record
source timestamps and deletion markers separately. Compare inventories, byte
counts and streamed SHA256 for every live object, followed by a clean second
comparison. Keep archives separate from the central Loki live buckets.
Pause after verification.

## Stage 3: remove bundled services (separate approval)

The service-removal configuration must not be merged until the owner accepts
Stage 2 archive evidence. Review the archive PR first. Require both full SHA256
comparisons, matching keys/bytes/metadata, unchanged source inventories, private
buckets without expiration, durable rollback credentials and healthy central
Loki. Do not use a successful chart render as proof that the archive exists.

After approval and merge, fetch the merged Flux source, resume the `openebs`
Kustomization to apply the disabled component values, then resume its HelmRelease.
Wait for the release to become Ready. Verify the bundled Loki/MinIO StatefulSets,
Alloy DaemonSet and their chart-owned resources disappear, while all six source
PVCs remain Bound and PVs retain their data. Confirm the Hostpath provisioner,
StorageClasses and application claims remain available. Verify central Loki
recent/historical queries, alert evaluation and Vector delivery after rollout.
Keep the standalone `storage/minio-data-hdd` claim; it is retained data, not a
running MinIO server. Pause before removing any source data.

For rollback, suspend reconciliation, revert the removal commit, restore the
saved MinIO credential Secret privately, and resume with the previously recorded
chart configuration. Reuse the retained claims and verify all three ingesters
and MinIO replicas recover. Never re-enable automatic PVC deletion.


Explicitly disable OpenEBS Loki, Alloy and Loki MinIO. Remove their obsolete RBAC,
configuration and Vector filter. Update existing checks and documentation to
expect one Loki backend; add no new tests. Keep storage provisioners, CRDs,
application volumes and retained logging source volumes. Use existing render,
schema and security checks, then verify live logging. Pause before any source
data deletion. RustFS SSD cutover and ZFS changes are separate work.
