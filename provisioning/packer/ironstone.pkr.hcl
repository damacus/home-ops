# Note: The ARM builder is provided by the mkaczanowski/packer-builder-arm container
# and doesn't need to be installed via packer init. The ansible-local provisioner
# is built into Packer core.

# =============================================================================
# Required Variables
# =============================================================================

variable "target_board" {
  type        = string
  description = "Target board: rpi5 or rock5b"

  validation {
    condition     = contains(["rpi5", "rock5b"], var.target_board)
    error_message = "The target_board must be 'rpi5' or 'rock5b'."
  }
}

variable "image_type" {
  type        = string
  description = "Image type: gold or flasher"

  validation {
    condition     = contains(["gold", "flasher"], var.image_type)
    error_message = "The image_type must be 'gold' or 'flasher'."
  }
}

variable "artifact_name" {
  type        = string
  description = "Output artifact filename (e.g., rpi5-gold-abc1234-20231215.img)"
  default     = ""
}

# =============================================================================
# Network Configuration (from environment)
# =============================================================================

variable "nfs_server" {
  type        = string
  description = "NFS server IP address"
  default     = env("NFS_SERVER")
}

variable "nfs_share" {
  type        = string
  description = "NFS share path"
  default     = env("NFS_SHARE")
}

variable "cloud_init_url" {
  type        = string
  description = "Cloud-init datasource URL"
  default     = env("CLOUD_INIT_URL")
}

variable "k3s_vip" {
  type        = string
  description = "K3s API server VIP"
  default     = env("K3S_VIP")
}

# =============================================================================
# K3s Configuration
# =============================================================================

variable "k3s_version" {
  type        = string
  description = "K3s version to install (e.g., v1.31.3+k3s1). Empty for latest."
  default     = env("K3S_VERSION")
}

# =============================================================================
# Armbian Image URLs (pinned versions with checksums)
# =============================================================================

variable "rpi5_image_url" {
  type        = string
  description = "Debian Trixie image URL for RPi5"
  default     = "https://raspi.debian.net/tested/20231111_raspi_4_trixie.img.xz"
}

variable "rpi5_sha_url" {
  type        = string
  description = "SHA checksum URL for RPi5 image"
  default     = "https://raspi.debian.net/tested/20231111_raspi_4_trixie.img.xz.sha256"
}

variable "rock5b_image_url" {
  type        = string
  description = "Armbian image URL for Rock 5B"
  default     = "https://dl.armbian.com/rock-5b/Trixie_vendor_minimal"
}

variable "rock5b_sha_url" {
  type        = string
  description = "SHA checksum URL for Rock 5B image"
  default     = "https://dl.armbian.com/rock-5b/Trixie_vendor_minimal.sha"
}

variable "rock5b_spi_loader_url" {
  type        = string
  description = "Rock 5B SPI loader URL"
  default     = "https://dl.radxa.com/rock5/sw/images/loader/rock-5b/release/rock-5b-spi-image-gd1cf491-20240523.img"
}

# =============================================================================
# Locals
# =============================================================================

locals {
  # Select image URL based on target board
  image_url = var.target_board == "rpi5" ? var.rpi5_image_url : var.rock5b_image_url
  sha_url   = var.target_board == "rpi5" ? var.rpi5_sha_url : var.rock5b_sha_url

  # Output filename - use artifact_name if provided, otherwise generate
  output_filename = var.artifact_name != "" ? var.artifact_name : "${var.target_board}-${var.image_type}.img"

  # Network config with defaults
  nfs_server     = coalesce(var.nfs_server, "192.168.1.243")
  nfs_share      = coalesce(var.nfs_share, "/volume1/NFS")
  cloud_init_url = coalesce(var.cloud_init_url, "http://provision.ironstone.casa:8080/")
  k3s_vip        = coalesce(var.k3s_vip, "192.168.1.200")
  k3s_version    = var.k3s_version != null ? var.k3s_version : ""

  # SPI loader
  rock5b_spi_loader_url = coalesce(var.rock5b_spi_loader_url, "https://dl.radxa.com/rock5/sw/images/loader/rock-5b/release/rock-5b-spi-image-gd1cf491-20240523.img")
}

source "arm" "rpi5" {
  file_urls             = [var.rpi5_image_url]
  file_checksum_type    = "none"
  file_target_extension = "xz"
  file_unarchive_cmd    = ["xz", "-d", "$ARCHIVE_PATH"]
  image_build_method    = "reuse"
  image_path            = "builds/${local.output_filename}"
  image_size            = "6G"
  image_type            = "dos"

  # Debian RPi images have two partitions (from fdisk -l):
  # 1. Boot partition (FAT32) - start 8192, end 1048575 (~508M)
  # 2. Root partition (ext4) - start 1048576
  image_partitions {
    name         = "boot"
    type         = "c"
    start_sector = "8192"
    filesystem   = "vfat"
    size         = "256M"
    mountpoint   = "/boot"
  }

  image_partitions {
    name         = "root"
    type         = "83"
    start_sector = "1048576"
    filesystem   = "ext4"
    size         = "0"
    mountpoint   = "/"
  }

  image_chroot_env = ["PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"]
  # qemu_binary_source_path      = ""
  # qemu_binary_destination_path = ""

  image_chroot_mounts {
    mount_type       = "proc"
    source_path      = "proc"
    destination_path = "/proc"
  }
  image_chroot_mounts {
    mount_type       = "sysfs"
    source_path      = "sysfs"
    destination_path = "/sys"
  }
  image_chroot_mounts {
    mount_type       = "bind"
    source_path      = "/dev"
    destination_path = "/dev"
  }
  image_chroot_mounts {
    mount_type       = "devpts"
    source_path      = "/devpts"
    destination_path = "/dev/pts"
  }
}

source "arm" "rock5b" {
  file_urls             = [var.rock5b_image_url]
  file_checksum_type    = "none"
  file_target_extension = "xz"
  file_unarchive_cmd    = ["xz", "-d", "$ARCHIVE_PATH"]
  image_build_method    = "reuse"
  image_path            = "builds/${local.output_filename}"
  image_size            = "6G"
  image_type            = "dos"

  # Armbian images typically have a single partition starting at 32768
  image_partitions {
    name         = "root"
    type         = "83"
    start_sector = "32768"
    filesystem   = "ext4"
    size         = "0"
    mountpoint   = "/"
  }

  image_chroot_env = ["PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"]
  qemu_binary_source_path      = "/usr/bin/qemu-aarch64-static"
  qemu_binary_destination_path = "/usr/bin/qemu-aarch64-static"

  image_chroot_mounts {
    mount_type       = "proc"
    source_path      = "proc"
    destination_path = "/proc"
  }
  image_chroot_mounts {
    mount_type       = "sysfs"
    source_path      = "sysfs"
    destination_path = "/sys"
  }
  image_chroot_mounts {
    mount_type       = "bind"
    source_path      = "/dev"
    destination_path = "/dev"
  }
  image_chroot_mounts {
    mount_type       = "devpts"
    source_path      = "/devpts"
    destination_path = "/dev/pts"
  }
}

build {
  sources = ["source.arm.rpi5", "source.arm.rock5b"]

  provisioner "shell" {
    inline = [
      "rm -f /etc/resolv.conf",
      "echo 'nameserver 1.1.1.1' > /etc/resolv.conf",
      "apt-get update",
      "apt-get install -y python3 python3-pip ansible",
      "mkdir -p /tmp/ansible"
    ]
  }

  # Upload Ansible playbook and roles to the image
  provisioner "file" {
    source      = "../ansible"
    destination = "/tmp/ansible"
  }

  # Run Ansible playbook
  provisioner "shell" {
    inline = [
      "cd /tmp/ansible && ansible-playbook playbook.yaml --connection=local -i 'localhost,' --extra-vars 'target_board=${var.target_board} image_type=${var.image_type} nfs_server=${local.nfs_server} nfs_share=${local.nfs_share} cloud_init_url=${local.cloud_init_url} k3s_version=${local.k3s_version} k3s_vip=${local.k3s_vip} rock5b_spi_loader_url=${local.rock5b_spi_loader_url}'"
    ]
  }

  provisioner "shell" {
    inline = [
      "rm -rf /tmp/ansible",
      "apt-get remove -y ansible",
      "apt-get autoremove -y",
      "apt-get clean"
    ]
  }

  post-processor "shell-local" {
    environment_vars = [
      "NFS_SERVER=${local.nfs_server}",
      "NFS_SHARE=${local.nfs_share}"
    ]
    inline = [
      "./upload_to_nfs.sh builds/${local.output_filename} ${var.target_board} ${var.image_type}"
    ]
  }
}
