#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    cloud-init \
    conntrack \
    curl \
    gdisk \
    gnupg \
    hdparm \
    htop \
    iptables \
    iputils-ping \
    ipvsadm \
    libseccomp2 \
    lm-sensors \
    locales \
    multipath-tools \
    net-tools \
    nfs-common \
    nvme-cli \
    open-iscsi \
    parted \
    psmisc \
    python3 \
    rsync \
    smartmontools \
    socat \
    unattended-upgrades \
    unzip \
    util-linux \
    vim

if dpkg -l | grep -q zram; then
    apt-get remove -y --purge armbian-zram-config zram-tools || true
fi
rm -f /etc/default/armbian-zram-config /etc/default/zramswap
sed -i '/swap/d' /etc/fstab

if [ -d /tmp/overlay ]; then
    rsync -a /tmp/overlay/ /
fi

# Armbian enables root SSH in the main config during image preparation. That
# value is read before sshd_config.d includes, so enforce the policy here after
# the overlay has been copied into the image.
sshd_config=/etc/ssh/sshd_config
if [ -f "$sshd_config" ]; then
    sed -i '1iPermitRootLogin no' "$sshd_config"
fi

if ! id -u pi >/dev/null 2>&1; then
    useradd --create-home --uid 1000 --groups adm,sudo --shell /bin/bash pi
else
    usermod --append --groups adm,sudo --shell /bin/bash pi
fi
install -d -m 0700 -o pi -g pi /home/pi/.ssh
chown -R pi:pi /home/pi
chmod 0750 /home/pi
chmod 0700 /home/pi/.ssh
chmod 0600 /home/pi/.ssh/authorized_keys
chmod 0440 /etc/sudoers.d/pi
passwd -l pi
passwd -l root

locale-gen en_GB.UTF-8
update-locale LANG=en_GB.UTF-8
ln -snf /usr/share/zoneinfo/Europe/London /etc/localtime
printf '%s\n' 'Europe/London' >/etc/timezone

chmod 0755 /usr/local/bin/ironstone-init.sh /usr/local/bin/k3s
chown root:root /usr/local/bin/ironstone-init.sh /usr/local/bin/k3s
ln -sf k3s /usr/local/bin/kubectl
ln -sf k3s /usr/local/bin/crictl
ln -sf k3s /usr/local/bin/ctr
install -d -m 0700 /etc/rancher/k3s
chmod 0600 /etc/rancher/k3s/registries.yaml
systemctl disable k3s.service || true
rm -f /etc/systemd/system/*.wants/k3s.service

systemctl enable apt-daily.timer apt-daily-upgrade.timer
systemctl enable iscsid multipathd

rm -rf /var/lib/cloud/instance /var/lib/cloud/instances /var/lib/cloud/data
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
truncate -s 0 /etc/hostname
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
rm -f /root/.not_logged_in_yet
touch /root/.config_done

chmod +x /etc/initramfs-tools/scripts/local-premount/nvme-rescan
update-initramfs -u -k all
apt-get clean
rm -rf /var/lib/apt/lists/*
