# Ironstone Hardware Workflow: Rock 5B+

This document outlines the hardware provisioning strategy, focusing on eliminating the SD card step and selecting the appropriate bootloader.

## 1. Boot Strategy: U-Boot vs. UEFI (EDK2)

### The Landscape

| Feature              | Vendor U-Boot (Recommended)       | Mainline U-Boot                 | UEFI (EDK2)                   |
|:---------------------|:----------------------------------|:--------------------------------|:------------------------------|
| **Kernel Support**   | Rockchip Vendor Kernel (5.10/6.1) | Mainline Linux                  | Standard Linux ISOs (Generic) |
| **Hardware Support** | 100% (NPU, VPU, HDMI, 2.5G)       | Good, but often missing VPU/NPU | Experimental, varies          |
| **Complexity**       | Low (Baked into Armbian)          | Medium                          | High (PC-like experience)     |
| **Stability**        | High                              | Medium                          | Low (Experimental)            |

### Recommendation: Vendor U-Boot

For a **Kubernetes Node (K3s)**, stability and hardware access (especially if we use the NPU for Frigate/AI later) are paramount.

*   **Decision**: Stick with **Armbian Vendor Kernel + Vendor U-Boot**.
*   **Why**: It ensures the 2.5GbE NICs, NVMe controller, and NPU work reliably without "hacking" device trees. Armbian handles the U-Boot updates automatically.

---

## 2. Flashing Workflow: Eliminating the SD Card

You have two methods to flash the NVMe drive directly, avoiding the "SD Card Shuffle."

### Method A: USB-to-NVMe Adapter (Simplest)

If you have a USB-to-NVMe adapter/enclosure:

1.  **Build** the image on your Mac (`./build.sh`).
2.  **Mount** the NVMe drive to your Mac via USB.
3.  **Flash** directly:

    ```bash
    # BE CAREFUL TO SELECT THE CORRECT DEVICE
    sudo dd if=output/images/Ironstone-Rock5b.img of=/dev/diskN bs=4M status=progress
    ```

4.  **Install** NVMe into Rock 5B+.
5.  **Boot**. (Ensure SPI Flash is empty or has a compatible bootloader).

### Method B: Maskrom Mode (Direct USB Flashing)

You can flash the NVMe drive while it is installed in the Rock 5B+ using the USB-C port.

**Prerequisites:**

*   USB-A to USB-C cable (connected to Rock 5B+ USB-C port).
*   `rkdeveloptool` (Linux/macOS) or `RKDevTool` (Windows).
*   Rockchip RK3588 SPL Loader (`rk3588_spl_loader_v1.08.111.bin` or similar).

**Steps:**

1.  **Enter Maskrom Mode**:
    *   Power off board.
    *   Press and hold the **Maskrom Button** (usually near the USB-C port or M.2 slot).
    *   Plug in USB-C cable to PC.
    *   Release button.
    *   Verify: `rkdeveloptool ld` should show `DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=xxx Maskrom`.

2.  **Initialize RAM**:

    ```bash
    rkdeveloptool db rk3588_spl_loader_v1.08.111.bin
    ```

3.  **Flash to NVMe**:
    *   *Note: Direct NVMe writing via `rkdeveloptool` depends on the loader capability. Often it exposes the storage as a USB Mass Storage device.*
    *   If `db` (download boot) works, try running a script to expose UMS (USB Mass Storage).
    *   **Alternative**: Use `rkdeveloptool` to write the **SPI Bootloader** only, then boot from NVMe.

    **The "Mini-Loader" Trick**:

    1.  Flash a small generic bootloader to SPI Flash using `rkdeveloptool`.
    2.  This bootloader looks for an OS on NVMe.
    3.  If NVMe is empty, some bootloaders expose it as a USB Disk to the PC.
    4.  Flash image to that USB Disk.

### Method C: The "Rescue" SD Card (Reliable Fallback)

If Method B proves finicky (Maskrom can be temperamental with cables/power), the single SD card approach is robust:

1.  Flash 4GB SD card with "Flasher Image" (Armbian minimal).
2.  Boot Rock 5B+ from SD.
3.  `curl` your custom image from your NAS/PC.
4.  `dd` to `/dev/nvme0n1`.
5.  Reboot & Remove SD.

---

## 3. Implementation Plan

1.  **Build System**: We have fixed the recursive Docker error.
2.  **SPI Flash**: We will ensure the image builds with the correct bootloader configuration so that once flashed to NVMe, it boots without needing an SD card present.
    *   Armbian handles this by installing the bootloader to the start of the NVMe drive.
    *   The Rock 5B+ looks at SPI Flash -> eMMC -> SD -> NVMe (Order varies by configuration).
    *   **Action**: We may need to flash the SPI with a modern U-Boot if the board refuses to boot from NVMe initially.
