# Ironstone Provisioning

Build Armbian-based K3s server images for Rock 5B+ boards.

## Quick Start

```bash
# Build the image
task provisioning:build

# Copy to ~/Downloads for flashing
task provisioning:copy

# Flash with Raspberry Pi Imager or Etcher
# Boot the board and wait for cloud-init (~5 minutes)

# Test the running node
task provisioning:audit host=<node-ip>
```

## How It Works

1. **Build Time** (`armbian-build/build.sh`)
   - Clones Armbian build framework
   - Applies userpatches (customize-image.sh, overlay files)
   - Installs K3s binary and airgap images
   - Produces flashable `.img` file

2. **First Boot** (cloud-init)
   - Installs packages
   - Creates `pi` user with SSH keys from GitHub
   - Sets hostname from MAC address (node-XXXXXX)
   - Renders K3s config from template
   - Retrieves cluster token from NFS
   - Starts K3s and joins cluster

## Configuration

Edit `config.env`:

```bash
K3S_VIP="192.168.1.220"
NFS_SERVER="unas.ironstone.casa"
NFS_SHARE="/var/nfs/shared/nfs"
K3S_VERSION="v1.33.2+k3s1"
```

## Task Commands

| Command                                      | Description            |
|----------------------------------------------|------------------------|
| `task provisioning:build`                    | Build Armbian image    |
| `task provisioning:copy`                     | Copy to ~/Downloads    |
| `task provisioning:clean`                    | Remove build artifacts |
| `task provisioning:audit host=<ip>`          | Test running node      |
| `task provisioning:audit-image mount=<path>` | Test mounted image     |

## Documentation

See [docs/README.md](docs/README.md) for full documentation.
