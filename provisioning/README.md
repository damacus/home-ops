# Radxa 5B+ provisioning

This directory builds a hardened, unjoined Armbian image for the Radxa Rock
5B+. A flashed host does not contain a cluster address or token and does not
start K3s. Joining a host is a separate, explicit SSH operation against an
existing healthy cluster.

## Bootstrap

Install the pinned repository tools and initialise the pinned Armbian
submodule when you intend to build:

```console
mise install
git submodule update --init -- provisioning/armbian-build/armbian-build-repo
```

The build uses Docker Desktop directly. Lima is not part of the steady-state
toolchain. Check Docker before a build:

```console
mise run provisioning:docker:doctor
mise run provisioning:docker:usage
```

Docker Desktop must expose an ARM64 daemon with at least 8 GiB RAM. The host
must have at least 50 GiB free space.

## Image workflow

Inspect the complete resolved build plan without network or Docker changes:

```console
mise run provisioning:build -- --dry-run
```

The live build derives the sole K3s version from both resources in
`kubernetes/apps/system-upgrade/k3s/app/plan.yaml`. It downloads the ARM64
binary, air-gap archive, and ARM64 checksum list, verifies both payloads, and
runs the pinned Armbian checkout through its Docker build path. The build plan
captures the full home-ops commit before work starts; the driver re-checks
that commit, repository cleanliness, and the Armbian pin after compilation and
after restoring any pre-existing ignored `userpatches` tree, then writes the
artifacts:

```console
mise run provisioning:build
```

Each build produces this canonical set under `provisioning/artifacts/`:

```text
radxa-5b-plus-<YYYYMMDD>-<commit>.img.xz
radxa-5b-plus-<YYYYMMDD>-<commit>.img.xz.sha256
radxa-5b-plus-<YYYYMMDD>-<commit>.manifest.json
```

Verify the set before flashing, staging, or publishing:

```console
mise run provisioning:verify provisioning/artifacts/<release-id>.img.xz
mise run provisioning:flash provisioning/artifacts/<release-id>.img.xz /dev/<device> --dry-run
mise run provisioning:flash provisioning/artifacts/<release-id>.img.xz /dev/<device>
```

`flash` uses the local image only. It requires a real whole-disk block device,
rejects the disk containing `/` and any disk with mounted child partitions,
checks capacity, reports size and model, and requires the exact validated
device path to be typed before writing.

## Host lifecycle

After first boot, cloud-init sets the hostname from the first usable Ethernet
MAC address. The `pi` account uses the baked approved key; SSH passwords,
keyboard-interactive authentication, and root login are disabled, unattended
upgrades are active, and K3s remains
dormant.

Enrolment requires a healthy existing cluster and a Ready control-plane source
node. It copies the shared K3s settings and server token over SSH without
printing the token, removes source-node values, writes the target files with
mode `0600`, and only then enables K3s:

```console
mise run provisioning:enrol <host> --dry-run
mise run provisioning:enrol <host>
mise run provisioning:enrol <host> --source-node <ready-control-plane>
```

Use `--replace` only when replacing a Kubernetes node with the same hostname.
The existing node must be NotReady, and the live command shows its identity
and requires `replace <hostname>` before reading the token or deleting it.
Enrolment completes only after the node is Ready with control-plane and etcd
roles. A replacement dry-run emits one JSON plan with the existing state in
its `replacement` field.
Inspect all nodes or one host with:

```console
mise run provisioning:status
mise run provisioning:status <host>
mise run provisioning:status --rtk
```

Retirement validates the target hostname, sudo access, and K3s unit before it
drains the node. It then disables and stops K3s, deletes the node object, and
removes local configuration and state. It requires the node name to be typed:

```console
mise run provisioning:retire <node> <host> --dry-run
mise run provisioning:retire <node> <host>
```

## Artifacts and cleanup

Both distribution commands validate the local three-file set first and
support a non-mutating plan:

```console
mise run provisioning:stage <artifact> --dry-run
mise run provisioning:release <artifact> --dry-run
```

Staged files live under
`/var/nfs/shared/nfs/provisioning/images/radxa-5b-plus/<release-id>/`. GitHub
releases use the release ID as their tag.

Cleanup never runs a global Docker prune. `clean` and `artifacts:clean` remove
only local Armbian build/output data, including Armbian's generated `.tmp`
work directory. `docker:purge` ignores only known generated `cache`, `output`,
and `.tmp` state while rejecting changed source helpers, then delegates to the
pinned Armbian checkout. Docker Desktop space reclamation is opt-in:

```console
mise run provisioning:clean --dry-run
mise run provisioning:clean --deep --dry-run
mise run provisioning:docker:purge --dry-run
mise run provisioning:docker:purge --reclaim --dry-run
```

The one-time legacy cleanup is separate. It requires typing `ironstone` and
uses only `limactl unprotect`, `limactl delete`, and
`limactl prune --keep-referred`:

```console
mise run provisioning:lima:remove --dry-run
```

## Zero-cluster recovery

`provisioning:enrol` cannot recover a cluster with no healthy server. Recovery
is deliberately manual. Before starting, have all of these prerequisites:

1. The verified image, checksum, and manifest for the cluster's K3s version.
2. Console or key-based `pi` SSH access to a flashed host.
3. The intended stable Kubernetes API endpoint and working node networking.
4. An offline copy of the original server token, handled as a secret and
   installed as mode `0600`; it is never stored in this repository.
5. For datastore recovery, a compatible K3s etcd snapshot and its encryption
   material from the same cluster.

On one seed host, write a reviewed server config with the stable endpoint and
the required restore or cluster-initialisation settings, install the token
out-of-band, restore the snapshot when applicable, and start K3s manually.
Confirm `/readyz` and the recovered nodes and workloads before using
`provisioning:enrol` for any other host. Do not invent a new token when
restoring encrypted cluster data.

Detailed image and NVMe notes are under [`docs/`](docs/).
