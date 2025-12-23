# Golden Image Architecture

## Overview

This document describes the architecture for building and deploying golden images for k3s cluster nodes on Raspberry Pi 5 and Rock 5B hardware.

## Design Principles

1. **Zero-Touch Deployment**: Once the flasher SD card is inserted and power applied, no further human input is required until the node appears as `Ready` in Kubernetes.

2. **MAC-Based Identity**: Each node derives its identity (hostname, configuration) from its MAC address via Matchbox.

3. **Immutable Golden Image**: The golden image is generic and identical for all nodes of the same board type. Customisation happens at first boot.

4. **Centralised Configuration**: Node-specific configuration is managed in Matchbox, not baked into images.

## Architecture Diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                           BUILD PIPELINE                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌──────────────┐    ┌──────────────────┐    ┌──────────────────────────┐  │
│   │  Mac/Linux   │───▶│  Docker          │───▶│  packer-plugin-cross     │  │
│   │  Host        │    │  (privileged)    │    │  container               │  │
│   └──────────────┘    └──────────────────┘    └──────────────────────────┘  │
│                                                          │                   │
│                                                          ▼                   │
│                              ┌──────────────────────────────────────────┐   │
│                              │  QEMU (ARM64 emulation)                  │   │
│                              │  └── Chroot into image                   │   │
│                              │      └── Ansible provisioner             │   │
│                              │          ├── Install packages            │   │
│                              │          ├── Install k3s binary          │   │
│                              │          ├── Configure cloud-init        │   │
│                              │          ├── Create k3s-init service     │   │
│                              │          └── Seal image                  │   │
│                              └──────────────────────────────────────────┘   │
│                                                          │                   │
│                                                          ▼                   │
│                              ┌──────────────────────────────────────────┐   │
│                              │  Golden Image (*.img)                    │   │
│                              │  └── Uploaded to NFS                     │   │
│                              └──────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                           DEPLOYMENT FLOW                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌──────────────┐    ┌──────────────────┐    ┌──────────────────────────┐  │
│   │  Flasher SD  │───▶│  Node boots      │───▶│  Flasher clones golden   │  │
│   │  Card        │    │  from SD         │    │  image to NVMe           │  │
│   └──────────────┘    └──────────────────┘    └──────────────────────────┘  │
│                                                          │                   │
│                                                          ▼                   │
│                              ┌──────────────────────────────────────────┐   │
│                              │  Node reboots from NVMe                  │   │
│                              └──────────────────────────────────────────┘   │
│                                                          │                   │
└──────────────────────────────────────────────────────────┼──────────────────┘
                                                           │
┌──────────────────────────────────────────────────────────┼──────────────────┐
│                           FIRST BOOT SEQUENCE            │                   │
├──────────────────────────────────────────────────────────┼──────────────────┤
│                                                          ▼                   │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  1. systemd starts cloud-init.service                                │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                      │                                       │
│                                      ▼                                       │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  2. cloud-init fetches metadata from Matchbox                        │  │
│   │     GET https://provision.ironstone.casa/metadata?mac=XX:XX:XX   │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                      │                                       │
│                                      ▼                                       │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  3. Matchbox matches MAC to group, returns:                          │  │
│   │     - hostname: "node-a"                                             │  │
│   │     - k3s_token: "SECRET"                                            │  │
│   │     - k3s_url: "https://192.168.1.200:6443"                          │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                      │                                       │
│                                      ▼                                       │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  4. cloud-init applies configuration:                                │  │
│   │     - Sets hostname                                                  │  │
│   │     - Writes /etc/rancher/k3s/config.yaml                            │  │
│   │     - Generates SSH host keys                                        │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                      │                                       │
│                                      ▼                                       │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  5. k3s-init.service starts (After=cloud-init.target)                │  │
│   │     - Enables k3s-agent.service                                      │  │
│   │     - Starts k3s-agent.service                                       │  │
│   │     - Disables itself (one-time setup)                               │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                      │                                       │
│                                      ▼                                       │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  6. k3s joins cluster using token from config                        │  │
│   │     - Node appears as Ready in kubectl                               │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Components

### Golden Image Contents

| Component               | Purpose                               |
|-------------------------|---------------------------------------|
| Debian Trixie / Armbian | Base operating system                 |
| k3s binary              | Kubernetes distribution (not started) |
| cloud-init              | First-boot configuration              |
| k3s-init.service        | Starts k3s after cloud-init           |
| Kernel modules          | overlay, br_netfilter, ip_vs, etc.    |
| Sysctl settings         | IP forwarding, bridge netfilter       |

### Matchbox Configuration

Matchbox serves as the cloud-init datasource, matching nodes by MAC address:

```json
{
  "id": "node-a",
  "name": "Node A (RPi5)",
  "profile": "rpi5-gold",
  "selector": {
    "mac": "d8:3a:dd:xx:xx:xx"
  },
  "metadata": {
    "hostname": "node-a",
    "k3s_token": "SECRET_TOKEN_HERE"
  }
}
```

### K3s Configuration

Cloud-init writes `/etc/rancher/k3s/config.yaml`:

```yaml
server: https://192.168.1.200:6443
token: "SECRET_TOKEN_HERE"
```

## MAC-Based Naming

The MAC address is used as the unique identifier for each node:

1. **Discovery**: cloud-init sends MAC address to Matchbox
2. **Matching**: Matchbox looks up MAC in its groups
3. **Response**: Matchbox returns node-specific metadata
4. **Application**: cloud-init sets hostname and writes k3s config

### Adding a New Node

1. Get the MAC address of the new node's primary interface
2. Add a new group in Matchbox ConfigMap:

  ```json
   {
     "id": "new-node",
     "profile": "rpi5-gold",
     "selector": { "mac": "XX:XX:XX:XX:XX:XX" },
     "metadata": {
       "hostname": "new-node",
       "k3s_token": "CLUSTER_TOKEN"
     }
   }
   ```

1. Flash the node with the flasher SD card
2. Node will automatically join the cluster

## Alternative: Local MAC-Based Naming

If Matchbox is unavailable, a fallback script can derive hostname from MAC:

```bash
#!/bin/bash
MAC=$(cat /sys/class/net/eth0/address | tr -d ':')
HOSTNAME="k3s-${MAC: -6}"
hostnamectl set-hostname "$HOSTNAME"
```

This provides unique hostnames without external dependencies, but loses the human-readable naming.

## Build Process

The build uses `build-native.sh` running inside a Lima VM on ARM64 Mac. This avoids Docker/Packer binfmt_misc issues by using native ARM64 chroot.

```bash
task provisioning:build-and-copy board=rpi5
```

## Security Considerations

1. **K3s Token**: Injected at runtime via Matchbox, not baked into image
2. **SSH Keys**: Removed during sealing, regenerated on first boot
3. **Machine ID**: Cleared during sealing, regenerated on first boot
4. **Cloud-init State**: Cleared to ensure first-boot runs

## Troubleshooting

### Node doesn't get hostname

1. Check Matchbox logs: `kubectl logs -n default deploy/matchbox`
2. Verify MAC address in Matchbox group selector
3. Check cloud-init logs on node: `journalctl -u cloud-init`

### K3s doesn't start

1. Check k3s-init logs: `journalctl -u k3s-init`
2. Verify `/etc/rancher/k3s/config.yaml` exists
3. Check k3s logs: `journalctl -u k3s-agent`

### Node doesn't join cluster

1. Verify K3s token is correct
2. Check network connectivity to K3s VIP (192.168.1.200)
3. Verify firewall rules allow 6443/tcp
