# Flashing Radxa 5B+ Nodes

This guide explains how to flash the Armbian image to a new Radxa 5B+ node using the provided script.

## Prerequisites

- A computer with an SD card reader.
- A microSD card (at least 16GB recommended).
- The `flash-radxa.sh` script located in `scripts/`.

## Steps

1.  **Insert the SD Card**: Insert your microSD card into your computer.
2.  **Run the Script**:
    Navigate to the root of the repository and run:
    ```bash
    ./scripts/flash-radxa.sh
    ```
3.  **Follow Prompts**:
    - The script will download the image if it's not already present.
    - It will list available drives. **Carefully identify your SD card.**
    - Enter the device name (e.g., `sdb` or `mmcblk0`).
    - Confirm the action by typing `flash`.
4.  **Wait for Completion**: The flashing process may take several minutes.
5.  **Boot the Node**:
    - Remove the SD card and insert it into the Radxa 5B+.
    - Power on the node.

## Troubleshooting

- **Permission Denied**: Ensure the script is executable (`chmod +x scripts/flash-radxa.sh`) and you have `sudo` privileges.
- **Wrong Drive**: Double-check the drive size and name using `lsblk` before confirming.
