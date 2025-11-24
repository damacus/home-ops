# Project Ironstone: Zero-Touch Provisioning

This directory contains the build pipeline for creating "Zero-Touch" bare-metal Kubernetes nodes (RPi5 & Rock 5B+).

## Architecture

The pipeline produces two artifacts per board:

1. **Gold Master** (`*-gold.img`): The production OS with K3s installed but not started.
2. **Flasher** (`*-flasher.img`): A utility image that boots, updates firmware, clones the Gold Master from NFS to NVMe, and shuts down.

## Usage

**Prerequisites:**

- Docker Desktop (Mac)
- `K3S_TOKEN` environment variable set

**Build Command:**

```bash
export K3S_TOKEN="your-secret-token"
./build.sh [board] [type]
```

**Examples:**

```bash
# Build Gold Master for RPi5 (uploads to NFS)
./build.sh rpi5 gold

# Build Flasher for RPi5 (keeps local)
./build.sh rpi5 flasher

# Build Gold Master for Rock 5B+
./build.sh rock5b gold
```

## Artifacts

- **Gold Master**: Automatically uploaded to `192.168.1.243:/volume1/NFS`.
- **Flasher**: Output to `provisioning/packer/builds/`. Flash this to an SD card using Etcher/dd.

## Configuration

- **Packer**: `provisioning/packer/ironstone.pkr.hcl`
- **Ansible**: `provisioning/ansible/`
- **Scripts**: `provisioning/scripts/` (if any)

## Network Dependencies

- **NFS Server**: `192.168.1.243:/volume1/NFS` (Must be accessible during build for Gold Master upload)
- **K3s VIP**: `192.168.1.200` (Hardcoded in bootstrap script)
