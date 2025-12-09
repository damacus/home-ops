# Simple Armbian Golden Image Builder

Minimal build process for creating a Rock 5B+ image with pre-installed packages for Kubernetes.

## Prerequisites

- Docker (running)
- Git
- ~50GB free disk space
- Internet connection

## Quick Start

```bash
cd provisioning/simple
chmod +x build.sh
./build.sh
```

Or specify a different board:

```bash
./build.sh rock-5b        # Rock 5B (non-plus)
./build.sh rock-5b-plus   # Rock 5B+ (default)
```

The build takes approximately 30-60 minutes depending on your system.

## Output

Built images are placed in `./output/`:

- `*.img.xz` - Compressed image ready to flash
- `*.img.xz.sha` - SHA checksum for verification

## Flashing

```bash
# Decompress
xz -dk output/Armbian_*.img.xz

# Flash to SD card (replace /dev/sdX with your device)
sudo dd if=output/Armbian_*.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Or use [balenaEtcher](https://etcher.balena.io/) which handles `.img.xz` directly.

## Customisation

### Packages

Edit `lib.config` to modify the package list:

```bash
PACKAGE_LIST_ADDITIONAL="$PACKAGE_LIST_ADDITIONAL your-package"
```

### Board

Pass the board name as an argument:

```bash
./build.sh rock-5b-plus   # Rock 5B+ (default)
./build.sh rock-5b        # Rock 5B
```

### Release

Edit `build.sh` to change the Debian release:

```bash
RELEASE="bookworm"    # Debian Bookworm (stable) - default
RELEASE="trixie"      # Debian Trixie (testing)
```

## Included Packages

The following packages are pre-installed for Kubernetes node preparation:

| Package | Purpose |
|---------|---------|
| `apt-transport-https` | HTTPS apt transport |
| `ca-certificates` | CA certificates |
| `conntrack` | Connection tracking for iptables |
| `curl` | HTTP client |
| `gdisk` | GPT disk partitioning |
| `hdparm` | Disk parameter utility |
| `htop` | Process viewer |
| `iptables` | Firewall |
| `ipvsadm` | IPVS administration |
| `libseccomp2` | Seccomp library |
| `lm-sensors` | Hardware monitoring |
| `net-tools` | Network utilities |
| `nfs-common` | NFS client |
| `nvme-cli` | NVMe management |
| `open-iscsi` | iSCSI initiator |
| `parted` | Partition editor |
| `python3` | Python 3 runtime |
| `python3-kubernetes` | Kubernetes Python client |
| `smartmontools` | SMART monitoring |
| `socat` | Socket relay |
| `unzip` | Archive extraction |

## Troubleshooting

### Build fails with permission errors

Ensure Docker can run privileged containers:

```bash
docker run --rm --privileged hello-world
```

### Out of disk space

The build requires ~50GB. Clean up with:

```bash
rm -rf armbian-build/output/images/*
rm -rf armbian-build/cache/*
```

### Network timeouts

The build downloads packages from Debian mirrors. Retry or use a VPN if mirrors are slow.
