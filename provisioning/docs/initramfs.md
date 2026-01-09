 Initramfs Boot Issues - NVMe Root Filesystem

## Problem Summary

After copying the system from SD card to NVMe, the system fails to boot with:

```text
ALERT! UUID=e5bbdf6c-43c1-4d16-88bb-d85ed8a8404a does not exist. Dropping to a shell!
```

## Root Cause (CONFIRMED 2025-12-31)

**The Crucial P310 NVMe drive does NOT automatically enumerate its namespace at boot.**

The NVMe controller initializes successfully (`/dev/nvme0` exists), and the namespace is valid,
but the kernel doesn't create the block device (`/dev/nvme0n1`) until a manual rescan is triggered.

This is a **firmware/driver compatibility issue** specific to the **Crucial CT1000P310SSD8** drive.

## Hardware Comparison

| Node        | Board    | NVMe Model             | NVMe Firmware | Boot Status       |
|-------------|----------|------------------------|---------------|-------------------|
| node-0b06a7 | Rock 5B+ | TEAM TM8FP6001T        | SN15169       | ✅ Works           |
| node-0b06df | Rock 5B+ | Crucial CT1000P310SSD8 | VACR001       | ❌ Requires rescan |

## Why This Happens

1. NVMe controller initializes and allocates host memory buffer
2. Namespace exists and is valid (`nvme id-ns` works)
3. Kernel's automatic namespace enumeration fails silently
4. `/dev/nvme0n1` block device is never created
5. Root mount fails because UUID cannot be found
6. Manual `echo 1 > /sys/class/nvme/nvme0/rescan_controller` triggers enumeration
7. After rescan, `/dev/nvme0n1` and `/dev/nvme0n1p1` appear immediately

## Previous Incorrect Assumptions

1. ~~NVMe drivers not in initramfs~~ - Driver is built into kernel (`CONFIG_BLK_DEV_NVME=y`)
2. ~~UUID mismatch~~ - UUID is correct
3. ~~Timing issue~~ - `rootdelay=10` doesn't help because namespace is never enumerated

## Debugging Commands

### In Initramfs Shell

```bash
# Check visible block devices
ls -la /dev/nvme*
ls -la /dev/sd*
ls -la /dev/mmcblk*
cat /proc/partitions

# Check loaded modules
cat /proc/modules | grep nvme

# Try loading NVMe modules manually
modprobe nvme
modprobe nvme_core

# Check devices again after loading modules
ls -la /dev/nvme*

# Check UUIDs
blkid

# View boot arguments
cat /proc/cmdline

# Manual mount test
mkdir -p /mnt
mount /dev/nvme0n1p1 /mnt
ls /mnt
```

### From SD Card Boot

```bash
# Check NVMe partition UUID
sudo blkid /dev/nvme0n1p1

# Compare with boot config
cat /boot/armbianEnv.txt
cat /boot/extlinux/extlinux.conf

# Check if NVMe modules are in initramfs
lsinitramfs /boot/initrd.img-$(uname -r) | grep nvme

# Add NVMe modules to initramfs
echo "nvme" | sudo tee -a /etc/initramfs-tools/modules
echo "nvme_core" | sudo tee -a /etc/initramfs-tools/modules

# Regenerate initramfs
sudo update-initramfs -u -k all

# Verify modules included
lsinitramfs /boot/initrd.img-$(uname -r) | grep nvme

# Fix UUID if mismatched
NVME_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p1)
echo "Actual NVMe UUID: $NVME_UUID"
sudo sed -i "s/rootdev=UUID=.*/rootdev=UUID=$NVME_UUID/" /boot/armbianEnv.txt
```

## Solution Checklist

- [ ] Verify NVMe modules (`nvme`, `nvme_core`) are in `/etc/initramfs-tools/modules`
- [ ] Regenerate initramfs with `update-initramfs -u -k all`
- [ ] Verify UUID in `/boot/armbianEnv.txt` matches actual NVMe partition UUID
- [ ] Copy updated initramfs to NVMe boot partition if separate
- [ ] Consider adding `rootdelay=10` to boot args if timing issue

## Session Log

### 2025-12-31 - Session 1: Initial Boot Failure

- **Issue**: UUID `d6dad6ba-dd28-4773-bc68-15dbe8067a33` not found at boot
- **Finding 1**: `/dev/nvme0` (controller char device) exists but NO block devices (`/dev/nvme0n1*`)
- **Finding 2**: `blkid` only shows `/dev/mtdblock0` - no NVMe partitions visible
- **Finding 3**: `cat /proc/modules > grep nvme` failed - module not loaded
- **Finding 4**: `modprobe nvme` and `modprobe nvme_core` ran but no block devices appeared

### 2025-12-31 - Session 2: Root Cause Analysis

- **Finding 5**: NVMe namespace exists and is healthy (`nvme id-ns` shows 1TB, 0% used, no errors)
- **Finding 6**: Namespace not appearing as `/dev/nvme0n1` until manual rescan
- **Finding 7**: `echo 1 > /sys/class/nvme/nvme0/rescan_controller` makes namespace appear
- **Finding 8**: initramfs has `nvme-fabrics.ko`, `nvme-tcp.ko` but missing base `nvme.ko`
- **Root Cause**: PCIe/NVMe initialization race condition on Rock 5B+ ARM SBC
  - armbian-config wipes partition table but doesn't trigger kernel rescan
  - NVMe controller initializes but namespace enumeration is delayed
  - Kernel scans for block devices before NVMe is fully ready
  - Base nvme.ko module missing from initramfs prevents early boot detection

### Solution

**Immediate**: Manual rescan after boot: `echo 1 | sudo tee /sys/class/nvme/nvme0/rescan_controller`

**Permanent Fix**:
- Add `rootdelay=10` to `/boot/armbianEnv.txt` for timing margin
- NVMe driver is built into kernel (`CONFIG_BLK_DEV_NVME=y`), no module needed
- The 10-second delay allows PCIe/NVMe to fully initialize before root mount

**Why modules aren't needed**:
- `nvme.ko` doesn't exist as a loadable module
- Driver is compiled into kernel (always available)
- Only fabric drivers (nvme-tcp, nvme-fc) are modules
- Issue is purely timing-based, not missing drivers

### 2025-12-31 - Session 3: System Migration Complete

- **MTD Flash**: Healthy, 16MB NOR flash (XT25F128B), U-Boot written successfully
- **NVMe**: 1TB drive, 9.5GB system copied, UUID `e5bbdf6c-43c1-4d16-88bb-d85ed8a8404a`
- **Boot Config**: `rootdev=UUID=e5bbdf6c-43c1-4d16-88bb-d85ed8a8404a`, `rootdelay=10`
- **Status**: ❌ Boot failed - NVMe namespace not enumerated

### 2025-12-31 - Session 4: Root Cause Identified

**Confirmed**: The issue is NOT timing, it's a **Crucial P310 firmware bug**.

- **node-0b06a7** (TEAM TM8FP6001T, firmware SN15169): Namespace enumerates automatically ✅
- **node-0b06df** (Crucial CT1000P310SSD8, firmware VACR001): Namespace requires manual rescan ❌

**Evidence from node-0b06df:**

```text
# Before rescan - only controller exists
ls -la /dev/nvme*
crw------- 1 root root 238, 0 /dev/nvme0

# After: echo 1 > /sys/class/nvme/nvme0/rescan_controller
ls -la /dev/nvme*
crw------- 1 root root 238, 0 /dev/nvme0
brw-rw---- 1 root disk 259, 0 /dev/nvme0n1
brw-rw---- 1 root disk 259, 1 /dev/nvme0n1p1
```

**NVMe data is intact** - system was successfully copied, just can't boot due to namespace issue.

## Solution: Initramfs Hook Script

Create `/etc/initramfs-tools/scripts/local-premount/nvme-rescan`:

```bash
#!/bin/sh
# Force NVMe namespace rescan for drives that don't auto-enumerate
# Required for: Crucial CT1000P310SSD8 (firmware VACR001)

PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0;;
esac

# Only run if NVMe controller exists but no block device
if [ -e /sys/class/nvme/nvme0 ] && [ ! -b /dev/nvme0n1 ]; then
    echo "NVMe controller found but no namespace - triggering rescan..."
    echo 1 > /sys/class/nvme/nvme0/rescan_controller
    # Wait for block device to appear
    for i in 1 2 3 4 5; do
        [ -b /dev/nvme0n1 ] && break
        sleep 1
    done
    if [ -b /dev/nvme0n1 ]; then
        echo "NVMe namespace enumerated successfully"
    else
        echo "WARNING: NVMe namespace still not available after rescan"
    fi
fi
```

**Installation:**

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

### 2025-12-31 - Session 5: SOLUTION VERIFIED ✅

**The initramfs hook script works!**

After installing the `nvme-rescan` script and rebuilding initramfs:

```text
# Boot successful - root mounted from NVMe
/dev/nvme0n1p1 on / type ext4 (rw,noatime,errors=remount-ro,commit=120)
```

**Steps performed:**

1. Created `/etc/initramfs-tools/scripts/local-premount/nvme-rescan`
2. Made it executable: `chmod +x`
3. Rebuilt initramfs: `update-initramfs -u -k all`
4. Copied updated initramfs to NVMe partition
5. Updated `/boot/armbianEnv.txt` to use NVMe UUID
6. Rebooted - **SUCCESS**

## Final Summary

| Issue                    | Root Cause                                              | Solution                                           |
|--------------------------|---------------------------------------------------------|----------------------------------------------------|
| NVMe boot fails          | Crucial P310 firmware doesn't auto-enumerate namespace  | Initramfs hook to trigger rescan                   |
| `/dev/nvme0n1` missing   | Namespace exists but kernel doesn't create block device | `echo 1 > /sys/class/nvme/nvme0/rescan_controller` |
| `rootdelay` doesn't help | Not a timing issue - namespace never enumerated         | Hook script runs before root mount                 |

## Affected Hardware

- **Drive**: Crucial CT1000P310SSD8 (firmware VACR001)
- **Board**: Rock 5B+ (Armbian, kernel 6.1.115-vendor-rk35xx)

## Files Created

- `/etc/initramfs-tools/scripts/local-premount/nvme-rescan` - Initramfs hook script
- `/Users/damacus/repos/damacus/home-ops/provisioning/scripts/nvme-rescan` - Source copy
