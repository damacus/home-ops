# Ironstone Provisioning

Build Armbian-based K3s server images for Rock 5B+ boards.

## Quick Start

```bash
# Build the image
task provisioning:build

# Copy to local machine for flashing
task provisioning:copy

# Flash with Raspberry Pi Imager or Etcher
# Boot the board and wait for cloud-init to complete

# Test the running node
task provisioning:audit host=<node-ip>
```

## Architecture

```text
┌─────────────────────────────────────────────────────────────────┐
│                        BUILD TIME                                │
│  ┌─────────────────┐    ┌─────────────────┐                     │
│  │  armbian-build/ │───▶│  Gold Image     │                     │
│  │  build.sh       │    │  (.img file)    │                     │
│  └─────────────────┘    └─────────────────┘                     │
│         │                       │                                │
│         ▼                       │                                │
│  ┌─────────────────┐            │                                │
│  │ customize-      │            │                                │
│  │ image.sh        │            │                                │
│  │ - cloud-init    │            │                                │
│  │ - k3s binary    │            │                                │
│  │ - clean state   │            │                                │
│  └─────────────────┘            │                                │
│         │                       │                                │
│         ▼                       │                                │
│  ┌─────────────────┐            │                                │
│  │ overlay/        │────────────┘                                │
│  │ - user-data     │                                             │
│  │ - k3s.service   │                                             │
│  │ - config.yaml   │                                             │
│  │   .template     │                                             │
│  └─────────────────┘                                             │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                        FIRST BOOT                                │
│  ┌─────────────────┐    ┌─────────────────┐                     │
│  │  cloud-init     │───▶│  Running Node   │                     │
│  │  user-data      │    │                 │                     │
│  └─────────────────┘    └─────────────────┘                     │
│         │                       │                                │
│         ▼                       ▼                                │
│  - Install packages      - k3s-init.sh fetches token from NFS   │
│  - Create pi user        - k3s.service starts                   │
│  - Set locale/timezone   - Node joins cluster                   │
│  - Fetch SSH keys        - etcd member added                    │
│  - Render k3s config                                            │
│  - Enable services                                               │
└─────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```text
provisioning/
├── armbian-build/           # Armbian build system
│   ├── build.sh             # Main build script
│   └── userpatches/
│       ├── customize-image.sh   # Image customization (build-time)
│       └── overlay/             # Files copied to image root
│           ├── etc/
│           │   ├── cloud/cloud.cfg.d/   # Cloud-init config
│           │   ├── ironstone/config     # Build-time variables
│           │   ├── rancher/k3s/         # K3s config template
│           │   ├── ssh/sshd_config.d/   # SSH hardening
│           │   ├── modules-load.d/      # Kernel modules
│           │   └── sysctl.d/            # Sysctl settings
│           ├── usr/local/bin/           # Scripts
│           │   ├── ironstone-init.sh    # Hostname from MAC
│           │   ├── k3s-init.sh          # Token from NFS
│           │   └── k3s-node-ip.sh       # Inject node IP
│           └── var/lib/cloud/seed/nocloud/
│               ├── user-data            # Cloud-init config
│               └── meta-data            # Instance metadata
├── config.env               # Build configuration
├── docs/                    # This documentation
└── tests/
    ├── inspec-image/        # Gold image validation
    └── inspec-node/         # Running node validation
```

## Configuration

Edit `config.env` before building:

```bash
# Network
NFS_SERVER="unas.ironstone.casa"  # NFS server with cluster token
NFS_SHARE="/var/nfs/shared/nfs"   # NFS share path
K3S_VIP="192.168.1.220"           # K3s API VIP

# K3s
K3S_VERSION="v1.33.2+k3s1"        # K3s version to install
```

## Task Commands

| Command                                      | Description               |
|----------------------------------------------|---------------------------|
| `task provisioning:build`                    | Build Armbian image       |
| `task provisioning:copy`                     | Copy image to ~/Downloads |
| `task provisioning:clean`                    | Remove build artifacts    |
| `task provisioning:audit host=<ip>`          | Test running node         |
| `task provisioning:audit-image mount=<path>` | Test mounted image        |

## Testing

### Image Tests (before boot)

```bash
# Mount the image and run tests
task provisioning:audit-image mount=/mnt/image
```

Tests verify:

- Cloud-init installed and configured
- K3s binary and symlinks present
- Config template exists
- SSH hardening in place
- Machine-id/hostname cleared

### Node Tests (after boot)

```bash
# SSH to node and run tests
task provisioning:audit host=192.168.1.100
```

Tests verify:

- Pi user created with SSH keys
- Cloud-init completed successfully
- K3s service running
- Node joined cluster as control-plane
- Packages installed
- Security hardening applied

## Troubleshooting

### Cloud-init not running

Check cloud-init status:

```bash
cloud-init status
cat /var/log/cloud-init-output.log
```

### K3s not starting

Check k3s-init service (token retrieval):

```bash
systemctl status k3s-init
journalctl -u k3s-init
```

Check k3s service:

```bash
systemctl status k3s
journalctl -u k3s -f
```

### Node not joining cluster

Verify token was retrieved:

```bash
ls -la /etc/rancher/k3s/cluster-token
```

Check config was rendered:

```bash
cat /etc/rancher/k3s/config.yaml
```

Verify network connectivity to VIP:

```bash
curl -k https://192.168.1.220:6443/healthz
```
