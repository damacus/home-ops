# Armbian Build Process for Rock 5B+

## Overview

This document describes the complete build process for creating a customized Armbian image for the Rock 5B+ with K3s pre-installed.

## Build Configuration

**Target Hardware:** Rock 5B+ (RK3588 SoC)

**Image Specifications:**

- **Board:** rock-5b-plus
- **Branch:** vendor (Rockchip vendor kernel 6.1.115)
- **Release:** Ubuntu Noble (24.04 LTS)
- **Build Type:** Minimal (no desktop)
- **Image Size:** 16GB (FIXED_IMAGE_SIZE=16384)
- **Bootloader:** Vendor U-Boot

## Prerequisites

- macOS or Linux host system
- Docker installed and running
- At least 30GB free disk space
- Internet connection for package downloads

## Build Steps

### 1. Clone and Setup

```bash
cd provisioning/armbian-build
git submodule update --init --recursive
```

### 2. Run the Build

```bash
./build.sh
```

The build process will:

- Launch Armbian's Docker-based build environment
- Download and cache required packages
- Build the kernel and bootloader
- Create the root filesystem
- Run customization scripts
- Generate the final image

**Build Time:** Approximately 1-2 hours (first build with cache population)

### 3. Verify the Build

```bash
./verify-image.sh armbian-build-repo/output/images/Armbian-*.img
```

This will mount the image and verify:

- K3s binary and airgap images are present
- Kernel headers are installed
- Required packages are installed
- System configuration (locale, timezone, ZRAM disabled)
- cloud-init is configured

## Build Artifacts

After a successful build, artifacts are located in:

```text
armbian-build-repo/output/images/
├── Armbian-unofficial_26.02.0-trunk_Rock-5b-plus_noble_vendor_6.1.115_minimal.img
├── Armbian-unofficial_26.02.0-trunk_Rock-5b-plus_noble_vendor_6.1.115_minimal.img.sha
└── Armbian-unofficial_26.02.0-trunk_Rock-5b-plus_noble_vendor_6.1.115_minimal.img.txt
```

**Image Size:** 16GB (16,179,869,184 bytes)

## Customizations Applied

The build includes the following customizations via `userpatches/customize-image.sh`:

### K3s Installation (REQ-K3S-001, REQ-K3S-002)

- K3s binary v1.31.4+k3s1 installed to `/usr/local/bin/k3s`
- K3s airgap images pre-downloaded to `/var/lib/rancher/k3s/agent/images/`
- K3s systemd service (`k3s-init.service`) configured

### System Packages (REQ-SYSTEM-001)

Essential packages for Kubernetes and system management:

- Container runtime dependencies: `conntrack`, `iptables`, `socat`
- Storage: `nvme-cli`, `nfs-common`, `open-iscsi`, `multipath-tools`
- Networking: `ipvsadm`, `net-tools`, `curl`
- Provisioning: `cloud-init`
- Monitoring: `htop`, `lm-sensors`, `smartmontools`

### Kernel Headers (REQ-K3S-003)

- Kernel headers package installed: `linux-headers-vendor-rk35xx`
- Required for eBPF-based networking (Cilium)

### System Configuration

- **Locale:** en_GB.UTF-8 (REQ-SYSTEM-004)
- **Timezone:** Europe/London (REQ-SYSTEM-003)
- **ZRAM:** Disabled (REQ-SYSTEM-005)
- **Swap:** Disabled (REQ-SYSTEM-006)

## Troubleshooting

### Build Failures

**Issue:** Docker recursion error

**Solution:** Do not pass `docker` argument to `compile.sh`. The build script handles Docker automatically.

**Issue:** Package not found errors

**Solution:** Check `customize-image.sh` for correct package names. Kernel headers are installed by Armbian build system, not manually.

**Issue:** Locale configuration errors

**Solution:** Ensure all locale variables (LANG, LANGUAGE, LC_ALL, LC_MESSAGES) are set consistently.

### Verification Failures

Run the verification script to identify missing components:

```bash
./verify-image.sh armbian-build-repo/output/images/Armbian-*.img
```

Review the output for specific failures and check the corresponding section in `customize-image.sh`.

## Next Steps

After successful build and verification:

1. **Flash the Image** - See `HARDWARE-WORKFLOW.md` for flashing methods
2. **Boot the Hardware** - Insert NVMe drive into Rock 5B+ and power on
3. **Provision with cloud-init** - Use NoCloud datasource with user-data/meta-data
4. **Initialize K3s Cluster** - The k3s-init service will start on first boot

## Build Logs

Build logs are stored in:

```text
armbian-build-repo/output/logs/log-build-<UUID>.log
```

Logs are also automatically uploaded to paste.armbian.com for sharing.

## Clean Build

To perform a clean build (remove all caches):

```bash
cd armbian-build-repo
sudo ./compile.sh clean
```

**Warning:** This will remove all cached packages and require a full rebuild.

## References

- Armbian Build Documentation: <https://docs.armbian.com/Developer-Guide_Build-Preparation/>
- Rock 5B+ Hardware: <https://wiki.radxa.com/Rock5/5b>
- K3s Documentation: <https://docs.k3s.io/>
