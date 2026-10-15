# Home Assistant and code-server SSD migration

> Historical migration procedure. HDD claim definitions and the stopped HDD
> RustFS release have now been retired from Flux. Do not follow the HDD
> retention or rollback instructions below as a current recovery procedure.
> Use the active SSD/Longhorn configuration and verified backups for recovery.
> See [HDD retirement](https://github.com/damacus/home-ops/blob/main/kubernetes/apps/storage/rustfs/HDD-RETIREMENT.md) for cleanup behaviour.

Both workloads share `/config` and must move together. The target is
`home-assistant-config-ssd` on `//unas.ironstone.casa/csi_ssd`. SMB presents every
entry as UID/GID 1000:1000, directories 0770 and files 0660. Both workloads use
`OnRootMismatch` to avoid recursive ownership changes at startup.

The PostgreSQL recorder remains on its existing database cluster. All files,
including old SQLite files and code-server extensions, are preserved.

## Migration procedure

1. Apply `app/ssd-storage.yaml` and the read-only source PV/PVC in
   `volsync-source.yaml`. Run `preflight.yaml` before starting the seed.
2. Apply the replication destination and source, then explicitly unpause both.
   The initial seed runs with both services available.
3. Hold both Flux Kustomizations and HelmReleases. Pause code-server's KEDA
   ScaledObject at zero replicas. Stop Home Assistant and code-server.
4. Trigger a new manual final sync. Wait for that exact trigger to succeed.
   Pause both replication objects before either service starts on SSD.
5. Run `verify-seed.yaml` with both trees read-only. Require no content/path
   differences and the expected target UID/GID and modes. If the documented
   legacy exceptions are present, first run `archive-legacy.yaml` and verify both
   archived payload hashes; never silently skip uncopied data.
6. Switch both HelmReleases to the SSD claim and resume Helm reconciliation.
   Verify Home Assistant HTTP, core configuration, recorder and startup logs.
   Temporarily start code-server and verify `/healthz` and shared config access.
7. Publish the configuration, wait for the merged source revision, then resume
   both Flux Kustomizations. Restore the original code-server KEDA behaviour.

## Rollback

Retain `home-assistant-nfs-csi-hdd` and its PV. Stop both writers, hold Flux/Helm,
and change both claims back together. The HDD contains the frozen pre-cutover
configuration. If configuration changed on SSD after cutover, decide how to
preserve those changes before rollback; never restart the old source-to-target
seed against the active SSD volume.

## Evidence

On 11 October 2026 the initial seed copied 3.19 GB successfully. The stopped
final sync `final-cutover-20261011` completed at 07:22:59 UTC. The full read-only
comparison checked 14,053 entries. All normal content/paths matched, with zero
ownership or mode mismatches. Two legacy files have representations incompatible
with the SMB view: `CuwGysJU` is interpreted as an emulated symlink, and a
January 2025 corrupt-backup filename contains private-use Unicode characters
remapped by SMB. `archive-legacy.yaml` preserved both byte-for-byte in
`.migration-legacy-files-20261011.tar.gz` and verified their hashes. The original
files remain on HDD. `verify-seed.yaml` excludes only these documented entries
and the additional archive.

Both services started on SSD. Home Assistant returned HTTP 200, its core config
was present, and PostgreSQL recorded fresh states and events. Both services
passed config write/read/rename/delete checks as UID/GID 1000. Code-server
returned HTTP 200 from `/healthz`; its original KEDA scale-to-zero behaviour
was restored. Startup logs also reported configuration issues (duplicate
Powercalc IDs, missing device references, Bluetooth capabilities and an Octopus
statistics import error); no config filesystem permission failure was observed.
