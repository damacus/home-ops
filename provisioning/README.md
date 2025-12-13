# Project Ironstone: Zero-Touch Provisioning

This directory contains the build pipeline for creating "Zero-Touch" bare-metal Kubernetes nodes (RPi5 & Rock 5B+).

## Architecture

The pipeline produces two artifacts per board:

1. **Gold Master** (`*-gold.img`): The production OS with K3s installed but not started.
2. **Flasher** (`*-flasher.img`): A utility image that boots, updates firmware, clones the Gold Master from NFS to NVMe, and shuts down.

## Quick Start

```bash
# 1. Configure your environment (copy and edit)
cp config.env config.env.local
vim config.env.local

# 2. Set up K3S token (choose one method)
export K3S_TOKEN="your-secret-token"
# OR
echo "your-secret-token" > ~/.secrets/k3s_token
# OR
mkdir -p secrets && echo "your-secret-token" > secrets/k3s_token

# 3. Validate configuration (dry run)
./build.sh --dry-run rpi5 gold

# 4. Build
./build.sh rpi5 gold
```

## Usage

```bash
./build.sh [OPTIONS] <board> <type>

Arguments:
  board     Target board: rpi5 | rock5b
  type      Image type: gold | flasher

Options:
  -h, --help      Show help message
  -n, --dry-run   Validate configuration without building
  -c, --clean     Remove old build artifacts before building
```

**Examples:**

```bash
# Build Gold Master for RPi5 (uploads to NFS)
./build.sh rpi5 gold

# Build Flasher for RPi5 (keeps local)
./build.sh rpi5 flasher

# Validate configuration without building
./build.sh --dry-run rock5b gold

# Clean old builds and build fresh
./build.sh --clean rpi5 gold
```

## Configuration

All configuration is externalised to `config.env`. Create a local override:

```bash
cp config.env config.env.local
```

### Configuration Options

| Variable               | Description                        | Default                                 |
|------------------------|------------------------------------|-----------------------------------------|
| `NFS_SERVER`           | NFS server IP                      | `192.168.1.243`                         |
| `NFS_SHARE`            | NFS share path                     | `/volume1/NFS`                          |
| `CLOUD_INIT_URL`       | Cloud-init datasource              | `http://provision.ironstone.casa:8080/` |
| `K3S_VIP`              | K3s API server VIP                 | `192.168.1.200`                         |
| `K3S_VERSION`          | K3s version to install             | `v1.31.3+k3s1`                          |
| `PACKER_CROSS_VERSION` | packer-plugin-cross version        | `latest`                                |
| `MIN_DISK_SPACE_GB`    | Minimum free disk space required   | `15`                                    |
| `VERSIONED_ARTIFACTS`  | Include git SHA/timestamp in names | `true`                                  |

### Secrets Management

The `K3S_TOKEN` can be provided via (in order of precedence):

1. Environment variable: `export K3S_TOKEN="..."`
2. File: `~/.secrets/k3s_token`
3. File: `./secrets/k3s_token`

**Security Note:** Secrets are mounted read-only into the build container at `/run/secrets/` and cleaned up after the build.

## Artifacts

- **Gold Master**: Automatically uploaded to NFS with both versioned and `*-latest.img` names
- **Flasher**: Output to `provisioning/packer/builds/`

With `VERSIONED_ARTIFACTS=true`, artifacts are named like:

```text
rpi5-gold-abc1234-20231215-143022.img
```

## Directory Structure

```text
provisioning/
├── README.md
├── build.sh              # Main build script
├── config.env            # Configuration (version controlled)
├── config.env.local      # Local overrides (gitignored)
├── secrets/              # Local secrets directory (gitignored)
├── docs/
│   └── ARCHITECTURE.md   # Detailed architecture documentation
├── ansible/
│   ├── playbook.yaml
│   └── roles/
│       ├── gold-master/  # K3s installation, cloud-init config
│       │   ├── tasks/
│       │   ├── templates/
│       │   │   ├── k3s-init.service.j2
│       │   │   ├── k3s-init.sh.j2
│       │   │   └── 99-ironstone-cloud-init.cfg.j2
│       │   └── files/
│       │       ├── k8s-modules.conf
│       │       └── k8s-sysctl.conf
│       └── flasher/      # Firmware update, NFS clone
└── packer/
    ├── ironstone.pkr.hcl # Packer configuration
    ├── upload_to_nfs.sh  # Post-build NFS upload
    └── builds/           # Build output directory
```

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed architecture documentation including:

- Build pipeline overview
- First-boot sequence
- MAC-based node identification via Matchbox
- K3s cluster join flow
- Troubleshooting guide

## Image Verification

All Armbian images are verified against SHA256 checksums from the official Armbian mirrors before use.

## Network Dependencies

- **NFS Server**: Must be accessible during build for Gold Master upload
- **Cloud-init Server**: Must be running at `CLOUD_INIT_URL` for node bootstrap
- **K3s VIP**: Used by nodes to join the cluster
