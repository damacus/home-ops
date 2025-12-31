#!/bin/bash
# =============================================================================
# Install packages required for Ironstone K3s nodes
# =============================================================================

set -euo pipefail

echo "Updating package lists..."
apt-get update

echo "Installing required packages..."
apt-get install -y --no-install-recommends \
  apt-transport-https \
  ca-certificates \
  conntrack \
  curl \
  dirmngr \
  gdisk \
  gnupg \
  hdparm \
  htop \
  iptables \
  iputils-ping \
  ipvsadm \
  libseccomp2 \
  lm-sensors \
  net-tools \
  nfs-common \
  nvme-cli \
  open-iscsi \
  parted \
  psmisc \
  python3 \
  python3-yaml \
  smartmontools \
  socat \
  unzip \
  util-linux \
  locales

echo "Package installation complete."
