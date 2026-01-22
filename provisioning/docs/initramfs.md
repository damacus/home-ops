# NVMe Initramfs Boot Fix

Crucial P310 NVMe drives don't auto-enumerate namespaces at boot. This causes boot failures on Rock 5B+ nodes.

For detailed investigation and session logs, see [initramfs-investigation.md](initramfs-investigation.md).

## Quick Fix (at initramfs prompt)

```bash
echo 1 > /sys/class/nvme/nvme0/rescan_controller
exit
```

## Permanent Fix (once booted)

### Option 1: Ansible (recommended)

```bash
task ansible:run -- playbooks/cluster-prepare.yaml --limit <node-name>
```

### Option 2: Manual Installation

```bash
sudo tee /etc/initramfs-tools/scripts/local-premount/nvme-rescan << 'EOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac

if [ -e /sys/class/nvme/nvme0 ] && [ ! -b /dev/nvme0n1 ]; then
    echo "NVMe rescan..."
    echo 1 > /sys/class/nvme/nvme0/rescan_controller
    for i in 1 2 3 4 5; do [ -b /dev/nvme0n1 ] && break; sleep 1; done
fi
EOF
sudo chmod +x /etc/initramfs-tools/scripts/local-premount/nvme-rescan
sudo update-initramfs -u -k all
```

## Affected Hardware

- **Drive**: Crucial CT1000P310SSD8 (firmware VACR001)
- **Board**: Rock 5B+ (Armbian, kernel 6.1.115-vendor-rk35xx)

## Persistence

The hook survives kernel upgrades via:

- **Existing nodes**: Ansible deploys `/etc/kernel/postinst.d/zz-nvme-rescan`
- **New nodes**: Hook baked into Armbian image at `provisioning/armbian-build/userpatches/overlay/`
