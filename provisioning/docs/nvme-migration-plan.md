# NVMe Migration Recovery Plan

## Problem Summary

node-0b06df fails to boot from NVMe after armbian-config migration. The NVMe namespace
disappears during boot, causing initramfs to drop to shell. node-0b06a7 boots from NVMe
successfully and has been running for 8+ days.

## 10-Step Recovery Plan

---

## Step 1: Recover node-0b06df to SD Card Boot (Physical Access Required)

**Goal**: Get the node bootable again from SD card.

At the initramfs prompt on node-0b06df, run:

```bash
# Mount SD card root partition
mkdir -p /mnt
mount /dev/mmcblk1p1 /mnt

# Check current boot config
cat /mnt/boot/armbianEnv.txt

# Revert to SD card boot
cat > /mnt/boot/armbianEnv.txt << 'EOF'
verbosity=1
bootlogo=false
console=both
docker_optimizations=off
extraargs=cma=256M
overlay_prefix=rockchip-rk3588
fdtfile=rockchip/rk3588-rock-5b-plus.dtb
rootdev=UUID=d32e4047-56c0-4b14-a640-d579cd8c99db
rootfstype=ext4
usbstoragequirks=0x2537:0x1066:u,0x2537:0x1068:u
EOF

# Verify the change
cat /mnt/boot/armbianEnv.txt

# Unmount and reboot
sync
umount /mnt
reboot
```

**Expected Result**: System boots from SD card, SSH accessible.

**If mount fails**: Try `mount /dev/mmcblk1p1 /mnt -t ext4` or check `blkid` for correct device.

---

## Step 2: Collect Full Diagnostics from node-0b06df (After Recovery)

**Goal**: Understand current state of the broken node.

SSH to node-0b06df and run this diagnostic script:

```bash
#!/bin/bash
# Save as: /tmp/diagnose-nvme.sh
# Run with: sudo bash /tmp/diagnose-nvme.sh > /tmp/nvme-diag.txt 2>&1

echo "=== SYSTEM INFO ==="
uname -a
cat /etc/os-release | head -5

echo -e "\n=== BLOCK DEVICES ==="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID

echo -e "\n=== BLKID ==="
blkid

echo -e "\n=== BOOT CONFIG ==="
cat /boot/armbianEnv.txt

echo -e "\n=== FSTAB ==="
cat /etc/fstab

echo -e "\n=== MTD INFO ==="
cat /proc/mtd
mtdinfo /dev/mtd0

echo -e "\n=== MTD BOOTLOADER CHECK ==="
dd if=/dev/mtd0 bs=512 count=1 2>/dev/null | strings | head -20

echo -e "\n=== NVME LIST ==="
nvme list

echo -e "\n=== NVME CONTROLLER INFO ==="
nvme id-ctrl /dev/nvme0 2>/dev/null | head -30

echo -e "\n=== NVME NAMESPACE INFO ==="
nvme id-ns /dev/nvme0 -n 1 2>/dev/null | head -30

echo -e "\n=== NVME SMART LOG ==="
nvme smart-log /dev/nvme0 2>/dev/null

echo -e "\n=== NVME LIST NAMESPACES ==="
nvme list-ns /dev/nvme0 2>/dev/null

echo -e "\n=== DMESG NVME/PCIE ==="
dmesg | grep -iE "nvme|pcie" | tail -50

echo -e "\n=== KERNEL CONFIG NVME ==="
grep CONFIG_BLK_DEV_NVME /boot/config-$(uname -r)

echo -e "\n=== INITRAMFS NVME MODULES ==="
lsinitramfs /boot/initrd.img-$(uname -r) | grep nvme

echo -e "\n=== /etc/initramfs-tools/modules ==="
cat /etc/initramfs-tools/modules

echo -e "\n=== MOUNT POINTS ==="
mount | grep -E "nvme|mmcblk"

echo -e "\n=== HISTORY (armbian-config usage) ==="
grep -i "armbian\|nand-sata\|dd\|rsync" ~/.bash_history 2>/dev/null | tail -20

echo -e "\n=== DONE ==="
```

**Save output**: `cat /tmp/nvme-diag.txt` and share it.

---

## Step 3: Collect Full Diagnostics from node-0b06a7 (Working Node)

**Goal**: Document the working configuration for comparison.

SSH to node-0b06a7 and run the same diagnostic script:

```bash
#!/bin/bash
# Save as: /tmp/diagnose-nvme.sh
# Run with: sudo bash /tmp/diagnose-nvme.sh > /tmp/nvme-diag.txt 2>&1

echo "=== SYSTEM INFO ==="
uname -a
cat /etc/os-release | head -5

echo -e "\n=== BLOCK DEVICES ==="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID

echo -e "\n=== BLKID ==="
blkid

echo -e "\n=== BOOT CONFIG ==="
cat /boot/armbianEnv.txt

echo -e "\n=== FSTAB ==="
cat /etc/fstab

echo -e "\n=== MTD INFO ==="
cat /proc/mtd
mtdinfo /dev/mtd0

echo -e "\n=== MTD BOOTLOADER CHECK ==="
dd if=/dev/mtd0 bs=512 count=1 2>/dev/null | strings | head -20

echo -e "\n=== NVME LIST ==="
nvme list

echo -e "\n=== NVME CONTROLLER INFO ==="
nvme id-ctrl /dev/nvme0 2>/dev/null | head -30

echo -e "\n=== NVME NAMESPACE INFO ==="
nvme id-ns /dev/nvme0 -n 1 2>/dev/null | head -30

echo -e "\n=== NVME SMART LOG ==="
nvme smart-log /dev/nvme0 2>/dev/null

echo -e "\n=== NVME LIST NAMESPACES ==="
nvme list-ns /dev/nvme0 2>/dev/null

echo -e "\n=== DMESG NVME/PCIE ==="
dmesg | grep -iE "nvme|pcie" | tail -50

echo -e "\n=== KERNEL CONFIG NVME ==="
grep CONFIG_BLK_DEV_NVME /boot/config-$(uname -r)

echo -e "\n=== INITRAMFS NVME MODULES ==="
lsinitramfs /boot/initrd.img-$(uname -r) | grep nvme

echo -e "\n=== /etc/initramfs-tools/modules ==="
cat /etc/initramfs-tools/modules

echo -e "\n=== MOUNT POINTS ==="
mount | grep -E "nvme|mmcblk"

echo -e "\n=== HISTORY (migration method) ==="
grep -iE "armbian|nand-sata|dd|rsync|cp.*nvme" ~/.bash_history /root/.bash_history 2>/dev/null | tail -30

echo -e "\n=== CHECK FOR DD MIGRATION EVIDENCE ==="
ls -la /root/*.sh 2>/dev/null
cat /root/*.sh 2>/dev/null | head -50

echo -e "\n=== DONE ==="
```

---

## Step 4: Compare SPI/MTD Flash Between Both Nodes

**Goal**: Identify differences in bootloader configuration.

Run on BOTH nodes:

```bash
#!/bin/bash
# Save as: /tmp/compare-spi.sh

echo "=== MTD PARTITION TABLE ==="
cat /proc/mtd

echo -e "\n=== MTD0 DETAILS ==="
mtdinfo -a

echo -e "\n=== SPI FLASH CHIP ==="
dmesg | grep -iE "spi.*nor|sfc_nor|xt25f"

echo -e "\n=== BOOTLOADER SIGNATURES ==="
echo "First 1KB of MTD0:"
dd if=/dev/mtd0 bs=1024 count=1 2>/dev/null | xxd | head -30

echo -e "\n=== U-BOOT ENV (if available) ==="
fw_printenv 2>/dev/null || echo "fw_printenv not available"

echo -e "\n=== EXTLINUX CONFIG ==="
cat /boot/extlinux/extlinux.conf 2>/dev/null || echo "No extlinux.conf"

echo -e "\n=== BOOT.SCR ==="
ls -la /boot/boot.scr 2>/dev/null || echo "No boot.scr"
```

---

## Step 5: Determine Original Migration Method

**Goal**: Find out how node-0b06a7 was migrated (dd vs armbian-config).

Check these on node-0b06a7:

```bash
# Check bash history for migration commands
sudo grep -iE "dd.*nvme|rsync.*nvme|armbian-config|nand-sata" /root/.bash_history ~/.bash_history 2>/dev/null

# Check for migration scripts
sudo ls -la /root/*.sh /home/*/*.sh 2>/dev/null

# Check system logs for armbian-config
sudo journalctl | grep -i "armbian\|install\|nand" | tail -50

# Check if there's evidence of dd usage
sudo dmesg | grep -i "copied\|cloned"

# Check partition table creation date (approximate)
sudo tune2fs -l /dev/nvme0n1p1 | grep -i "created\|mount"
```

**Key Question**: Was `dd` used to clone the entire disk, or was `armbian-config` used?

---

## Step 6: Document NVMe Namespace Behavior Differences

**Goal**: Understand why namespace disappears on node-0b06df.

Run on BOTH nodes:

```bash
#!/bin/bash
# Save as: /tmp/nvme-namespace-check.sh

echo "=== NVME CONTROLLER CAPABILITIES ==="
nvme id-ctrl /dev/nvme0 | grep -iE "nn|oacs|oncs|frmw"

echo -e "\n=== NAMESPACE MANAGEMENT SUPPORT ==="
nvme id-ctrl /dev/nvme0 | grep -i "oacs"
# Bit 3 of OACS indicates NS management support

echo -e "\n=== ALL NAMESPACES ==="
nvme list-ns /dev/nvme0 --all

echo -e "\n=== ACTIVE NAMESPACES ==="
nvme list-ns /dev/nvme0

echo -e "\n=== NAMESPACE 1 DETAILS ==="
nvme id-ns /dev/nvme0 -n 1

echo -e "\n=== NVME FEATURES ==="
nvme get-feature /dev/nvme0 -f 0x07 2>/dev/null  # Number of queues
nvme get-feature /dev/nvme0 -f 0x0a 2>/dev/null  # Timestamp

echo -e "\n=== PCIE LINK STATUS ==="
lspci -vvv 2>/dev/null | grep -A20 "Non-Volatile" | head -30
```

---

## Step 7: Create Reliable Migration Script

**Goal**: Create a tested, reliable migration process.

Based on findings, create this script (adjust after Step 5 findings):

```bash
#!/bin/bash
# migrate-to-nvme.sh - Reliable SD to NVMe migration
# Run from SD card boot

set -e

NVME_DEV="/dev/nvme0n1"
NVME_PART="${NVME_DEV}p1"
SD_ROOT="/dev/mmcblk1p1"

echo "=== Pre-flight Checks ==="

# Check NVMe is present
if [ ! -b "$NVME_DEV" ]; then
    echo "ERROR: NVMe device not found at $NVME_DEV"
    echo "Attempting rescan..."
    echo 1 > /sys/class/nvme/nvme0/rescan_controller
    sleep 2
    if [ ! -b "$NVME_DEV" ]; then
        echo "FATAL: NVMe still not found. Check hardware."
        exit 1
    fi
fi

# Check NVMe health
echo "=== NVMe Health Check ==="
nvme smart-log $NVME_DEV | grep -E "critical|temperature|percentage_used"

# Get SD card UUID
SD_UUID=$(blkid -s UUID -o value $SD_ROOT)
echo "SD Card UUID: $SD_UUID"

echo ""
read -p "Proceed with migration? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

echo "=== Creating Partition Table ==="
parted $NVME_DEV --script mklabel gpt
parted $NVME_DEV --script mkpart primary ext4 1MiB 100%

# Wait for partition to appear
sleep 2

echo "=== Formatting NVMe ==="
mkfs.ext4 -L rootfs $NVME_PART

# Get new UUID
NVME_UUID=$(blkid -s UUID -o value $NVME_PART)
echo "NVMe UUID: $NVME_UUID"

echo "=== Mounting Filesystems ==="
mkdir -p /mnt/nvme /mnt/sd
mount $NVME_PART /mnt/nvme
mount $SD_ROOT /mnt/sd -o ro

echo "=== Copying System (this takes a while) ==="
rsync -aAXv --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} /mnt/sd/ /mnt/nvme/

echo "=== Updating fstab on NVMe ==="
sed -i "s|UUID=$SD_UUID|UUID=$NVME_UUID|g" /mnt/nvme/etc/fstab

echo "=== Creating Boot Config for NVMe ==="
cat > /mnt/nvme/boot/armbianEnv.txt << EOF
verbosity=1
bootlogo=false
console=both
docker_optimizations=off
extraargs=cma=256M
overlay_prefix=rockchip-rk3588
fdtfile=rockchip/rk3588-rock-5b-plus.dtb
rootdev=UUID=$NVME_UUID
rootfstype=ext4
usbstoragequirks=0x2537:0x1066:u,0x2537:0x1068:u
EOF

echo "=== Cleanup ==="
sync
umount /mnt/nvme
umount /mnt/sd

echo ""
echo "=== Migration Complete ==="
echo "NVMe UUID: $NVME_UUID"
echo ""
echo "To boot from NVMe, update /boot/armbianEnv.txt on SD card:"
echo "  rootdev=UUID=$NVME_UUID"
echo ""
echo "Or use armbian-config to write bootloader to SPI flash."
```

---

## Step 8: Test Migration on node-0b06df

**Goal**: Verify the migration works before committing.

1. Boot from SD card
2. Run the migration script from Step 7
3. **DO NOT** change boot config yet
4. Manually test NVMe mount:

```bash
# Test mount
sudo mount /dev/nvme0n1p1 /mnt
ls -la /mnt
df -h /mnt

# Verify boot config on NVMe
cat /mnt/boot/armbianEnv.txt

# Verify fstab
cat /mnt/etc/fstab

# Unmount
sudo umount /mnt
```

5. Only proceed to Step 9 if mount test passes.

---

## Step 9: Implement Boot Configuration

**Goal**: Configure boot to use NVMe with SD card fallback.

**Option A: Simple NVMe Boot (like node-0b06a7)**

```bash
# Update SD card boot config to point to NVMe
sudo sed -i "s/rootdev=UUID=.*/rootdev=UUID=$NVME_UUID/" /boot/armbianEnv.txt

# Verify
cat /boot/armbianEnv.txt

# Reboot and test
sudo reboot
```

**Option B: Write Bootloader to SPI (Current Approach)**

```bash
sudo armbian-config
# System → Install → Boot from MTD Flash - system on NVMe
```

**Option C: Keep SD Card as Fallback (Safest)**

Keep SD card bootable, only change rootdev:

```bash
# On SD card, update boot config
sudo cp /boot/armbianEnv.txt /boot/armbianEnv.txt.backup

# Point to NVMe root
NVME_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p1)
sudo sed -i "s/rootdev=UUID=.*/rootdev=UUID=$NVME_UUID/" /boot/armbianEnv.txt

# If boot fails, you can:
# 1. Remove NVMe
# 2. Boot from SD card
# 3. Restore: sudo cp /boot/armbianEnv.txt.backup /boot/armbianEnv.txt
```

---

## Step 10: Document Final Solution

**Goal**: Record what worked for future reference.

Update `/provisioning/docs/initramfs.md` with:

1. Root cause of the issue
2. Working migration method
3. Boot configuration that works
4. Recovery procedure if boot fails

---

## Troubleshooting Reference

### If NVMe Namespace Disappears

```bash
# In initramfs or from SD card boot
echo 1 > /sys/class/nvme/nvme0/rescan_controller
sleep 2
ls -la /dev/nvme*

# If still missing, try PCIe rescan
echo 1 > /sys/bus/pci/rescan
sleep 2
ls -la /dev/nvme*

# Check namespace attachment
nvme list-ns /dev/nvme0 --all
nvme attach-ns /dev/nvme0 --namespace-id=1 --controllers=0
```

### If Boot Drops to Initramfs

```bash
# Mount SD card and revert
mkdir -p /mnt
mount /dev/mmcblk1p1 /mnt
# Edit /mnt/boot/armbianEnv.txt to use SD card UUID
nano /mnt/boot/armbianEnv.txt
sync
umount /mnt
reboot
```

### Hardware Differences

| Feature   | node-0b06a7 (Working) | node-0b06df (Broken)    |
|-----------|-----------------------|-------------------------|
| Board     | Rock 5B               | Rock 5B+                |
| DTB       | rk3588-rock-5b.dtb    | rk3588-rock-5b-plus.dtb |
| NVMe      | ?                     | ?                       |
| Migration | ? (likely dd)         | armbian-config          |

---

## Files to Compare

After running diagnostics, compare these files between nodes:

1. `/boot/armbianEnv.txt`
2. `/etc/fstab`
3. `/etc/initramfs-tools/modules`
4. `dmesg | grep nvme` output
5. `nvme id-ctrl` output
6. MTD/SPI flash contents
