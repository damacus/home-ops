# Rock 5B SPI Bootloader Flasher

This document provides instructions for manually updating the SPI bootloader firmware on a Radxa Rock 5B. The SPI bootloader is required for booting from NVMe SSD.

## Overview

The Rock 5B has a 16MB SPI NOR flash that stores the bootloader (U-Boot). This bootloader is responsible for:

- Initializing hardware (CPU, memory, storage)
- Loading the operating system kernel
- Enabling boot from NVMe SSD (not possible without SPI bootloader)

## Prerequisites

### Hardware

- Rock 5B board
- USB Type-C cable (for Maskrom mode flashing)
- Power supply for Rock 5B
- **Optional:** SD card or eMMC with Linux (for simple method)

### Software

- `rkdeveloptool` (Linux/macOS) or `RKDevTool` (Windows)
- Required firmware files (see Downloads section)

---

## Method 1: Simple Method (From Running Linux)

If your Rock 5B can boot Linux from SD card or eMMC, this is the easiest method.

### Step 1: Boot Linux on Rock 5B

Boot the Rock 5B with a Linux image on SD card or eMMC.

### Step 2: Download Required Files

```bash
# Download SPI clearing image
wget https://dl.radxa.com/rock5/sw/images/others/zero.img.gz
gzip -d zero.img.gz

# Download latest SPI bootloader (release version - recommended)
wget https://dl.radxa.com/rock5/sw/images/loader/rock-5b/release/rock-5b-spi-image-gd1cf491-20240523.img

# Verify checksums
md5sum zero.img
# Expected: 2c7ab85a893283e98c931e9511add182

md5sum rock-5b-spi-image-gd1cf491-20240523.img
# Expected: cf53d06b3bfaaf51bbb6f25896da4b3a
```

### Step 3: Verify SPI Flash is Available

```bash
ls /dev/mtdblock*
# Should show: /dev/mtdblock0
```

### Step 4: Clear and Flash SPI

```bash
# Clear SPI flash first (takes ~5 minutes)
sudo dd if=zero.img of=/dev/mtdblock0
sync

# Verify clear was successful
sudo md5sum /dev/mtdblock0 zero.img
# Both checksums should match

# Flash the new bootloader
sudo dd if=rock-5b-spi-image-gd1cf491-20240523.img of=/dev/mtdblock0
sync

# Verify flash was successful
sudo md5sum /dev/mtdblock0 rock-5b-spi-image-gd1cf491-20240523.img
# Both checksums should match
```

### Step 5: Reboot

```bash
sudo reboot
```

---

## Method 2: Advanced Method (Maskrom Mode from Host PC)

Use this method if the board cannot boot or you need to flash from an external computer.

### Step 1: Install rkdeveloptool

#### macOS (Apple Silicon / Intel)

```bash
# Install dependencies via Homebrew
brew install automake autoconf libusb pkg-config git wget

# Clone and build rkdeveloptool
git clone https://github.com/rockchip-linux/rkdeveloptool
cd rkdeveloptool
autoreconf -i
./configure
make -j $(sysctl -n hw.ncpu)

# Install to PATH
sudo cp rkdeveloptool /opt/homebrew/bin/
# Or for Intel Macs:
# sudo cp rkdeveloptool /usr/local/bin/

# Verify installation
rkdeveloptool --version
```

#### Linux (Debian/Ubuntu)

```bash
# Install dependencies
sudo apt-get install libudev-dev libusb-1.0-0-dev dh-autoreconf pkg-config

# Clone and build
git clone https://github.com/rockchip-linux/rkdeveloptool
cd rkdeveloptool
autoreconf -i
./configure
make

# Install
sudo cp rkdeveloptool /usr/local/bin/
```

### Step 2: Download Required Files

```bash
# RK3588 Loader (USB flashing helper)
wget https://dl.radxa.com/rock5/sw/images/loader/rk3588_spl_loader_v1.15.113.bin

# SPI Bootloader Image (release version - recommended)
wget https://dl.radxa.com/rock5/sw/images/loader/rock-5b/release/rock-5b-spi-image-gd1cf491-20240523.img

# Optional: Debug version (has U-Boot serial console enabled)
# wget https://dl.radxa.com/rock5/sw/images/loader/rock-5b/debug/rock-5b-spi-image-gd1cf491-20240523-debug.img

# Optional: Zero image for erasing SPI
wget https://dl.radxa.com/rock5/sw/images/others/zero.img.gz
gzip -d zero.img.gz
```

### Step 3: Enter Maskrom Mode

1. **Power off** the Rock 5B
2. **Remove** all bootable media (SD card, eMMC, NVMe)
3. **Press and hold** the golden/silver Maskrom button (located near the USB-C port)
4. **Connect** USB-C cable from Rock 5B to your computer
5. **Release** the Maskrom button
6. **Verify** the device is detected:

```bash
# macOS
lsusb
# Look for: ID 2207:350b Fuzhou Rockchip Electronics Co., Ltd.

# Linux
lsusb
# Look for: ID 2207:350b Fuzhou Rockchip Electronics Company

# Using rkdeveloptool
rkdeveloptool ld
# Should show: DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=xxx Maskrom
```

### Step 4: Flash SPI Bootloader

```bash
# Load the loader (initializes DRAM and prepares flash environment)
sudo rkdeveloptool db rk3588_spl_loader_v1.15.113.bin
# Output: Downloading bootloader succeeded.

# Write SPI bootloader image
sudo rkdeveloptool wl 0 rock-5b-spi-image-gd1cf491-20240523.img
# Output: Write LBA from file (100%)

# Reboot the device
sudo rkdeveloptool rd
```

---

## Erasing SPI Flash

If you need to completely erase the SPI flash (e.g., to restore factory state or troubleshoot):

### From Running Linux on Rock 5B

```bash
sudo dd if=/dev/zero of=/dev/mtdblock0
sync
```

### From Host PC via Maskrom Mode

```bash
# Enter Maskrom mode first (see Step 3 above)

# Load the loader
sudo rkdeveloptool db rk3588_spl_loader_v1.15.113.bin

# Write zero image to erase
sudo rkdeveloptool wl 0 zero.img

# Reboot
sudo rkdeveloptool rd
```

---

## rkdeveloptool Command Reference

| Command | Description |
|---------|-------------|
| `rkdeveloptool ld` | List connected devices in Maskrom mode |
| `rkdeveloptool db <loader.bin>` | Download bootloader (init DRAM, prepare flash) |
| `rkdeveloptool wl <sector> <image>` | Write image to storage at sector offset |
| `rkdeveloptool rd` | Reboot device |
| `rkdeveloptool ef` | Erase flash |
| `rkdeveloptool rfi` | Read flash info |

---

## Downloads Summary

### Loader Files

| File | Description | URL |
|------|-------------|-----|
| `rk3588_spl_loader_v1.15.113.bin` | USB flashing helper | [Download](https://dl.radxa.com/rock5/sw/images/loader/rk3588_spl_loader_v1.15.113.bin) |

### SPI Bootloader Images

| File | Description | URL |
|------|-------------|-----|
| `rock-5b-spi-image-gd1cf491-20240523.img` | Release (recommended) | [Download](https://dl.radxa.com/rock5/sw/images/loader/rock-5b/release/rock-5b-spi-image-gd1cf491-20240523.img) |
| `rock-5b-spi-image-gd1cf491-20240523-debug.img` | Debug (serial console enabled) | [Download](https://dl.radxa.com/rock5/sw/images/loader/rock-5b/debug/rock-5b-spi-image-gd1cf491-20240523-debug.img) |

### Utility Images

| File | Description | URL |
|------|-------------|-----|
| `zero.img.gz` | SPI clearing image | [Download](https://dl.radxa.com/rock5/sw/images/others/zero.img.gz) |

---

## Troubleshooting

### Device Not Detected in Maskrom Mode

1. **Check USB cable** - Try a different cable, some cables are charge-only
2. **Try different USB port** - Use a direct port on the motherboard, not a hub
3. **Hold Maskrom button longer** - Press before connecting USB, hold for 3-5 seconds
4. **Remove all storage** - Ensure no SD card, eMMC, or NVMe is connected
5. **Try USB 2.0** - Some USB 3.0 ports have compatibility issues

### "Creating Comm Object failed!" Error

This usually means a permission issue:

```bash
# Run with sudo
sudo rkdeveloptool ld

# Or add udev rules (Linux)
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="2207", MODE="0666", GROUP="plugdev"' | \
  sudo tee /etc/udev/rules.d/51-rockchip.rules
sudo udevadm control --reload-rules
```

### Flash Verification Failed

If checksums don't match after flashing:

1. Try flashing again
2. Use the zero.img to clear first, then flash
3. Check if the SPI flash chip is damaged

---

## References

- [Radxa Rock 5B SPI Flash Guide](https://wiki2.radxa.com/Rock5/install/spi)
- [Radxa Docs - Erase/Flash SPI Boot Firmware](https://docs.radxa.com/en/rock5/rock5b/low-level-dev/install-os/rkdevtool_spi)
- [Rockchip rkdeveloptool Wiki](https://opensource.rock-chips.com/wiki_Rkdeveloptool)
- [Radxa Docs - Maskrom Mode](https://docs.radxa.com/en/som/cm/cm3j/getting-started/install-os/maskrom/linux_macos)
