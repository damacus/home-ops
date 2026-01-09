#
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2025 David Maceachern
# This file is a part of the home-ops provisioning system
#
# Extension: nvme-rescan
# Purpose: Add initramfs hook to force NVMe namespace rescan for drives that
#          do not auto-enumerate (e.g., Crucial CT1000P310SSD8 with firmware VACR001)
#
# This is required for Rock 5B+ boards where certain NVMe drives don't properly
# enumerate their namespaces during early boot, causing root filesystem mount failures.

function extension_prepare_config__nvme_rescan_check() {
	display_alert "Checking sanity for" "${EXTENSION} in dir ${EXTENSION_DIR}" "info"
	local script_file_src="${EXTENSION_DIR}/local-premount/nvme-rescan"
	if [[ ! -f "${script_file_src}" ]]; then
		exit_with_error "Could not find '${script_file_src}'"
	fi
}

function pre_customize_image__inject_nvme_rescan_hook() {
	display_alert "Enabling" "nvme-rescan into initramfs" "info"

	# Create target directory if it doesn't exist
	local script_dir_dst="${SDCARD}/etc/initramfs-tools/scripts/local-premount"
	run_host_command_logged mkdir -p "${script_dir_dst}"

	# Copy the NVMe rescan script
	local script_file_src="${EXTENSION_DIR}/local-premount/nvme-rescan"
	local script_file_dst="${script_dir_dst}/nvme-rescan"
	run_host_command_logged cp -v "${script_file_src}" "${script_file_dst}"
	run_host_command_logged chmod -v +x "${script_file_dst}"

	display_alert "NVMe rescan hook installed" "${script_file_dst}" "info"
	return 0
}

function pre_customize_image__rebuild_initramfs_for_nvme() {
	# Ensure initramfs is rebuilt to include our hook
	# Note: This may already be done by customize-image.sh, but we ensure it here
	display_alert "Marking initramfs for rebuild" "nvme-rescan hook added" "info"
	# The actual rebuild happens in customize-image.sh via update-initramfs -u -k all
	return 0
}
