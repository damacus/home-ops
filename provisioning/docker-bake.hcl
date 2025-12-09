# =============================================================================
# Docker Bake Configuration for Packer ARM Builder
# =============================================================================
# Usage: docker buildx bake packer-arm-builder
# =============================================================================

variable "PACKER_BUILDER_VERSION" {
  default = "1.0.9"
}

variable "TIMEZONE" {
  default = "Europe/London"
}

group "default" {
  targets = ["packer-arm-builder"]
}

target "packer-arm-builder" {
  context    = "."
  dockerfile = "Dockerfile"

  args = {
    PACKER_BUILDER_VERSION = PACKER_BUILDER_VERSION
    TIMEZONE               = TIMEZONE
  }

  tags = ["ironstone-packer-builder:latest"]
}
