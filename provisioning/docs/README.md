# Radxa image design

The Radxa image is a reusable host baseline, not a cluster member. It contains
the current verified K3s ARM64 binary and air-gap archive but contains no API
address, server token, rendered K3s config, or node identity. The K3s systemd
unit exists and remains disabled until explicit enrolment.

Mise remains the operator-facing interface. Go under `cmd/provisioning` and
`internal/provisioning` owns the safety-critical planning, validation,
verification, flashing, and SSH lifecycle operations. The file tasks under
`.mise/tasks/provisioning/` compose those commands and handle simple Bash
orchestration such as Docker diagnostics, scoped cleanup, staging, and release
publishing.

## Build inputs

- The Armbian framework is the pinned git submodule at
  `armbian-build/armbian-build-repo`.
- `kubernetes/apps/system-upgrade/k3s/app/plan.yaml` is the sole K3s version
  authority; both Plan resources must agree.
- `armbian-build/userpatches/` contains portable image policy only.
- The build targets `rock-5b-plus`, the vendor kernel branch, Noble minimal
  userspace, no desktop, no kernel configuration, headers enabled, and the
  `nvme-rescan` extension. The compact initial image is explicitly 3072 MiB.
- Armbian's normal grow-on-first-boot root filesystem remains intact. There is
  no fixed `K3S_DATA` partition.

## Baked host state

The image creates a locked-password `pi` administrator with one approved SSH
key, locks root, disables SSH password, keyboard-interactive and its deprecated
challenge-response alias, and root login, and removes host keys,
machine ID, hostname, and cloud-init instance state. First boot derives a
`node-<mac-suffix>` hostname and regenerates host identity without downloading
keys or starting K3s.

Noble, Noble updates/security/backports, and Armbian packages receive
unattended upgrades. Kernel and firmware packages are not blacklisted and
automatic reboot is disabled. Kured, after later cluster enrolment, owns reboot
scheduling.

The image also includes the required Kubernetes, NFS, iSCSI, multipath, NVMe,
diagnostic, module, sysctl, registry, and NVMe initramfs configuration.

## Verification boundary

`mise run provisioning:verify` first checks that the image, checksum, and
manifest agree. It then mounts the detected ext4 root partition read-only in
a privileged ephemeral Docker container and checks the effective image state
there. The container returns only the structured report; it does not copy
`/etc`, `/home`, SSH material, or ownership metadata to a host bind mount.

- matching K3s payloads and manifest hashes;
- exact `pi` key and private modes;
- effective SSH policy, including both keyboard-interactive option names;
- unattended-upgrade origins, timer, and reboot policy;
- clean machine and cloud-init identity;
- dormant K3s with no config or token;
- no `K3S_DATA` input; and
- a private kubeconfig if one exists;
- the executable NVMe rootfs hook and its matching entry in the generated
  initramfs.

`--rootfs <directory> --raw` supplies an already available rootfs without
mounting an image or contacting Docker. It runs the same image-state checks;
only artifact manifest, payload-hash, and executable-version checks require a
real artifact set.

The operator workflow and manual zero-cluster recovery prerequisites are in
the parent [`README.md`](../README.md).

## Enrolment addressing

Enrolment retains the token-based SSH workflow, but the token is not read until
the source node, target identity, and any replacement confirmation have passed.
The target address defaults to the IPv4 source selected by its route to the
Kubernetes API. The command verifies that this address is assigned to that
interface and writes it as `node-ip` in the sanitised K3s configuration. Use
`mise run provisioning:enrol <host> --node-ip <IPv4>` when an explicit assigned
address is needed. Dry-runs and rejected replacements do not read the server
token.
