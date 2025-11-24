packer {
  required_plugins {
    arm = {
      version = ">= 1.0.0"
      source  = "github.com/mkaczanowski/arm"
    }
    ansible = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

variable "target_board" {
  type = string
}

variable "image_type" {
  type = string
}

variable "k3s_token" {
  type      = string
  sensitive = true
  default   = ""
}

# Armbian Redirect URLs
variable "rpi5_image_url" {
  type    = string
  default = "https://redirect.armbian.com/rpi5/Bookworm_minimal"
}

variable "rock5b_image_url" {
  type    = string
  default = "https://mirror.vinehost.net/armbian/dl/rock-5b/archive/Armbian_25.8.2_Rock-5b_bookworm_vendor_6.1.115_minimal.img.xz"
}

locals {
  image_url = var.target_board == "rpi5" ? var.rpi5_image_url : var.rock5b_image_url
  output_filename = "${var.target_board}-${var.image_type}.img"
}

source "arm" "ironstone" {
  file_urls             = [local.image_url]
  image_build_method    = "resize"
  image_path            = "builds/${local.output_filename}"
  image_size            = "4G"
  image_type            = "dos"
  partition_type_code   = "83"

  # QEMU binary source path in the container (mkaczanowski/packer-builder-arm)
  qemu_binary_source_path = "/usr/bin/qemu-aarch64-static"
  qemu_binary_destination_path = "/usr/bin/qemu-aarch64-static"
}

build {
  sources = ["source.arm.ironstone"]

  provisioner "shell" {
    inline = [
      "apt-get update",
      "apt-get install -y python3 python3-pip ansible"
    ]
  }

  provisioner "ansible-local" {
    playbook_file = "../ansible/playbook.yaml"
    role_paths    = [
      "../ansible/roles/gold-master",
      "../ansible/roles/flasher"
    ]
    extra_arguments = [
      "--extra-vars", "target_board=${var.target_board} image_type=${var.image_type} k3s_token=${var.k3s_token}"
    ]
  }

  provisioner "shell" {
    inline = [
      "apt-get remove -y ansible",
      "apt-get autoremove -y",
      "apt-get clean"
    ]
  }

  post-processor "shell-local" {
    inline = [
      "./upload_to_nfs.sh builds/${local.output_filename} ${var.target_board} ${var.image_type}"
    ]
  }
}
