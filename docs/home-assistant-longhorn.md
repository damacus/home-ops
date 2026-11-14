# Home Assistant config on Longhorn

Use this when Home Assistant or Code Server can't attach its configuration
volume, or when deciding which backup to restore. The
[migration history](history/home-assistant-longhorn-migration.md) explains the
move from SMB and the broken Python environment found during the copy.

## Shared volume

Both workloads use `home-assistant-config-longhorn`, a 50 GiB ReadWriteOnce
ext4 volume. Home Assistant's recorder stays in CNPG. The Python environment at
`/config/.venv` persists across replacements; the image rebuilds it after a
Home Assistant version or architecture change. Don't mount an emptyDir over it.

## Attachment and startup failures

Inspect the PVC, pod events and Longhorn attachment before restarting anything.
Code Server has required affinity to Home Assistant so both mount the RWO
volume on the same node.

Stop Code Server before moving Home Assistant to another node, so it can't
hold the old attachment. Pause its KEDA ScaledObject at zero for maintenance;
suspending Flux doesn't stop its HTTP or scheduled triggers. Restore its
original pause annotations once both workloads are healthy.

For Python or custom-integration errors, check the actual mount, executable,
ownership and logs. The old source environment was incomplete; copying it
back is not a repair.

## Recovery

Use native Home Assistant backups and check their configured destinations.
Longhorn replicas are not an independent backup.

The retained SMB/HDD source claims are historical copies. Once Longhorn has
new writes, they are no longer lossless rollback targets. The
[original copy procedure](history/home-assistant-longhorn-migration.md#migration)
records the exclusions and verification; don't repeat it on a running service.
