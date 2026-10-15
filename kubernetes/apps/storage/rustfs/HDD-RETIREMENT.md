# HDD volume retirement

The HDD-backed application claims and stopped RustFS HDD HelmRelease have been
removed from Flux after the SSD migration audit and backup/restore tests passed.
Active SSD and Longhorn claims are unchanged.

All eleven old HDD PVs use Retain. Removing their PVCs or PV records does not
erase NAS directories. Claims annotated with Flux prune disabled remain until
explicitly deleted; check that no pod or copy job references them first.

The three manually created read-only migration-source claims are outside Flux:
Home Assistant config, Paperless documents and RustFS data. Removing Flux
resources does not remove these claims or their PVs.

Review Released PVs after reconciliation. Do not remove SSD storage classes or
the shared NFS/SMB CSI drivers. NAS file deletion is a separate operation.
