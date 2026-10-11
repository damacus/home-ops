# OpenEBS logging retirement

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

Explicitly disable OpenEBS Loki, Alloy and Loki MinIO. Remove their obsolete RBAC,
configuration and Vector filter. Update existing checks and documentation to
expect one Loki backend; add no new tests. Keep storage provisioners, CRDs,
application volumes and retained logging source volumes. Use existing render,
schema and security checks, then verify live logging. Pause before any source
data deletion. RustFS SSD cutover and ZFS changes are separate work.
