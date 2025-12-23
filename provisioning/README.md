# Project Ironstone: Zero-Touch Provisioning

This directory contains the build pipeline for creating "Zero-Touch" bare-metal Kubernetes nodes (RPi5 & Rock 5B+).

`build-native.sh` is the build script, designed to run inside a Lima VM on ARM64 Mac.

## Architecture

The pipeline produces a **Gold Master** image (`*-gold.img`) for each board: the production OS with K3s installed but not started.

## Quick Start

```bash
# Build and copy image in one command (handles Lima VM automatically)
task provisioning:build-and-copy board=rpi5

# Flash to SD card
sudo dd if=./provisioning/packer/builds/rpi5-gold-*.img of=/dev/diskN bs=4M status=progress
```

## Prerequisites

- **Lima VM**: Install with `brew install lima`
- **Lima VM instance**: The `ironstone` VM will be started automatically if stopped

To create the Lima VM (first time only):

```bash
limactl create --name=ironstone template://default
```

## Usage

All commands are run via Task from the repository root:

```bash
task provisioning:build board=<board>      # Build image
task provisioning:copy board=<board>       # Copy to local
task provisioning:build-and-copy board=<board>  # Both
task provisioning:test                      # Run tests
```

**Arguments:**

- `board`: Target board (`rpi5` | `rock5b`), default: `rpi5`

**Examples:**

```bash
# Build Gold Master for RPi5 (default)
task provisioning:build-and-copy

# Build for Rock 5B
task provisioning:build-and-copy board=rock5b

# Just build (don't copy)
task provisioning:build board=rpi5

# Just copy (if already built)
task provisioning:copy board=rpi5
```

## Configuration

All configuration is externalised to `config.env`. Create a local override:

```bash
cp config.env config.env.local
```

### Configuration Options

| Variable         | Description            | Default                             |
|------------------|------------------------|-------------------------------------|
| `NFS_SERVER`     | NFS server IP          | `192.168.1.243`                     |
| `NFS_SHARE`      | NFS share path         | `/volume1/NFS`                      |
| `CLOUD_INIT_URL` | Cloud-init datasource  | `https://provision.ironstone.casa/` |
| `K3S_VIP`        | K3s API server VIP     | `192.168.1.220`                     |
| `K3S_VERSION`    | K3s version to install | `v1.31.3+k3s1`                      |

### Secrets Management

The `K3S_TOKEN` can be provided via (in order of precedence):

1. Environment variable: `export K3S_TOKEN="..."`
2. File: `~/.secrets/k3s_token`
3. File: `./secrets/k3s_token`

## Artifacts

Built images are output to `provisioning/packer/builds/` with names like:

```text
rpi5-gold-abc1234-20231215-143022.img
```

## Directory Structure

```text
provisioning/
├── README.md
├── build-native.sh       # Main build script (Lima VM)
├── config.env            # Configuration (version controlled)
├── config.env.local      # Local overrides (gitignored)
├── docs/
│   └── ARCHITECTURE.md   # Detailed architecture documentation
├── ansible/
│   ├── playbook.yaml
│   └── roles/
│       └── gold-master/  # K3s installation, cloud-init config
│           ├── tasks/
│           ├── templates/
│           └── files/
└── packer/
    └── builds/           # Build output directory
```

## Further Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed architecture documentation including:

- Build pipeline overview
- First-boot sequence
- MAC-based node identification via Matchbox
- K3s cluster join flow
- Troubleshooting guide

## Image Verification

All Armbian images are verified against SHA256 checksums from the official Armbian mirrors before use.

## Testing

The provisioning system includes comprehensive InSpec tests to validate cloud-init configuration.

### Test Profiles

| Profile          | Description                           | When to Use                            |
|------------------|---------------------------------------|----------------------------------------|
| `inspec-gold`    | Tests gold image before first boot    | Validate image is properly sealed      |
| `inspec-running` | Tests running system after cloud-init | Validate node is correctly provisioned |

### Running Tests

```bash
# Test a built gold image in Lima VM
task provisioning:test-cloud-init image=~/Downloads/rpi5-gold-abc123.img profile=gold

# Test a running node over SSH
task provisioning:audit-running host=192.168.1.100

# Run both gold and running tests
task provisioning:test-cloud-init image=~/Downloads/rpi5-gold-abc123.img profile=both
```

### Test Coverage

The tests verify:

- **Cloud-init**: Package installed, datasource configured, user-data/meta-data present
- **K3s**: Binary installed, symlinks created, service configured, config.yaml present
- **NFS Token**: Init script configured, NFS mount options, token retrieval logic
- **Security**: SSH hardening, host keys removed, machine-id cleared
- **System**: Kernel modules, sysctl settings, swap disabled, services enabled

### Feature List

See `provisioning/features/cloud-init.json` for the complete list of test cases.

## Network Dependencies

- **NFS Server**: Must be accessible for K3s token retrieval on first boot
- **K3s VIP**: Used by nodes to join the cluster (192.168.1.200)
