#!/bin/sh
# Force NVMe namespace rescan for drives that do not auto-enumerate
# Required for: Crucial CT1000P310SSD8 (firmware VACR001)
# Deployed by Ansible - do not edit manually

PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac

if [ -e /sys/class/nvme/nvme0 ] && [ ! -b /dev/nvme0n1 ]; then
    echo "NVMe rescan..."
    echo 1 > /sys/class/nvme/nvme0/rescan_controller
    for i in 1 2 3 4 5; do [ -b /dev/nvme0n1 ] && break; sleep 1; done
fi
