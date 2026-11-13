---
title: "Flashing Radxa 5B+ Nodes"
layout: documentation
---

# Flashing Radxa 5B+ Nodes

Use the Mise provisioning tasks to verify and flash a **local, verified Armbian
artifact set**. Flashing does not download an image or enrol the node into K3s.

## Prepare the image and target

Install the pinned tools with `mise install`. Obtain a verified release, or
follow the [provisioning guide](../provisioning/README.md) to build one. Keep the
three release files together:

- `<release-id>.img.xz`
- `<release-id>.img.xz.sha256`
- `<release-id>.manifest.json`

Insert the target card or disk and identify its **whole-disk device path** using
`diskutil list` on macOS or `lsblk` on Linux. Confirm its identity and capacity.
Do not select a partition or a disk containing data you need.

## Verify and flash

Run these commands from the repository root, substituting the actual release
file and device path:

```console
mise run provisioning:verify provisioning/artifacts/<release-id>.img.xz
mise run provisioning:flash provisioning/artifacts/<release-id>.img.xz /dev/<device> --dry-run
mise run provisioning:flash provisioning/artifacts/<release-id>.img.xz /dev/<device>
```

The dry run prints the selected local artifact and target; it does not establish
that the physical disk is safe to overwrite. The live command validates the
artifact set, checks the whole disk, rejects the running system's disk and
mounted child filesystems, checks capacity and displays the target identity.
It requires you to type the exact validated device path before writing.

Verification also checks the hardened image and the NVMe workaround inside its
root filesystem and generated initramfs. A checksum alone is not the complete
image verification.

## Boot and enrol separately

After flashing completes, eject the media if required, insert it into the Radxa
and boot it. The image deliberately contains no cluster token and does not start
K3s. Follow the [host lifecycle procedure](../provisioning/README.md#host-lifecycle)
to enrol the node explicitly using a healthy control-plane source.

If verification or disk inspection fails, resolve that failure before flashing.
Do not bypass the verified artifact workflow with the legacy
`scripts/flash-radxa.sh` helper.
