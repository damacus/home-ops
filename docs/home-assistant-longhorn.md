# Home Assistant config on Longhorn

Home Assistant and Code Server use `home-assistant-config-longhorn`, a 50 GiB
ReadWriteOnce ext4 volume with the existing Longhorn storage class's two replicas.
Home Assistant's recorder remains in CNPG. Native backup destinations stay unchanged.

The Python environment remains at `/config/.venv` on persistent storage. It survives
pod replacements; the container image rebuilds it when the Home Assistant version
or CPU architecture changes. Do not mount an emptyDir over this directory.

## Migration

1. Create the new PVC and set its provisioned PV's reclaim policy to `Retain`.
   The PVC has pruning disabled; preserve the SMB and HDD source claims as well.
2. Mount SMB read-only and Longhorn read-write in a temporary migration pod.
   Copy as UID/GID 1000 using `rsync -a`, without copying SMB ACLs or extended
   attributes. Exclude `/.venv/`, `/.ha_run.lock` and `/lost+found`.
   The source Python environment was incomplete and must be rebuilt.
3. Suspend the Home Assistant and Code Server Flux Kustomizations and HelmReleases.
   Record their original replica counts and Code Server's KEDA pause annotations.
   Set `autoscaling.keda.sh/paused-replicas: "0"` on ScaledObject `code`, then
   ensure the Code Server deployment is at zero with no running pods. Suspending
   Flux alone does not stop its HTTP or office-hours autoscaling triggers.
4. Stop Home Assistant gracefully, wait for its pod to terminate, then repeat the
   copy with `--delete`. The destination must be the new Longhorn volume.
5. Verify file contents and paths with `rsync -rlcn --delete` and the same exclusions.
   Require no differences, and verify ownership is UID/GID 1000. Remove the helper
   pod before starting Home Assistant on the new claim.
6. Adopt the manifests through Flux and restore reconciliation. Verify the actual
   mount, Python executable, custom integration imports, HTTP response and logs.
   Check that native backups are still configured. Restore Code Server's original
   KEDA pause annotations only after both workloads reference the new claim.

## Code Server

Code Server starts at zero replicas and retains its existing HTTP and office-hours
KEDA triggers after migration. Required pod affinity places it on Home Assistant's
node so both can use the RWO claim without an NFS layer.
If moving Home Assistant between nodes while Code Server is running, stop Code
Server first so its mount cannot keep the volume attached to the old node.

## Retention and recovery

Keep `home-assistant-config-ssd` and `home-assistant-nfs-csi-hdd` and their data.
After Longhorn receives new writes those copies are historical snapshots, not a
lossless rollback target. Use native Home Assistant backups for application recovery;
Longhorn replication is not an independent backup.
