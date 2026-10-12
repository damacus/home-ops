# Home Assistant SMB version-marker recovery

Home Assistant 2026.10.1 failed during configuration upgrade when Python opened
`/config/.HA_VERSION` with write/truncate semantics. Reading, opening for write
without truncation, and creating new files worked. Unix permissions were 0660
and the SMB CSI mount presented UID/GID 1000.

The UNAS backing file had a stored `user.DOSATTRIB` hidden bit: attributes 0x22
(archive and hidden). The repaired file stores 0x20 (archive only). Samba's
`hide dot files = yes` can still report dotfiles as hidden to clients, so an SMB
listing alone does not distinguish the stored attribute from this presentation.

## Diagnose and repair

1. Read the PVC/PV to identify the exact SMB share and subdirectory. Preserve
   the marker bytes and inspect its NAS-side `user.DOSATTRIB` with `getfattr`.
2. Reproduce the failure on a disposable copy preserving the file metadata.
   Use the application's UID and Python write/truncate operation.
3. For this incident, the existing authenticated macOS SMB mount provided the
   supported attribute change. Run `chflags nohidden` on the exact affected
   marker path in that mount. This updates SMB metadata without changing its
   contents. Do not apply recursive permission or attribute changes.
4. Verify the stored hidden bit is cleared, the original version bytes remain
   intact, and repeated write/truncate operations succeed from the application.
5. Allow Home Assistant to perform its own version upgrade. Never write the
   new version into the marker manually or remove it to bypass upgrade checks.
6. Verify the current image, marker version, HTTP response, restart count and
   a controlled restart. Remove any temporary Flux hold after Git and live
   state agree.

The 12 October 2026 check reproduced EACCES on a disposable copy retaining the
old metadata, then passed after the attribute correction. Both files had the
same Unix mode and ownership. No NFS export, SMB share-wide setting, credentials,
database or config contents needed changing. The original marker was retained
as `.HA_VERSION.recovery-20261012`; disposable probes were removed.
