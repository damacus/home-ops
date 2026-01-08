# frozen_string_literal: true

# =============================================================================
# Ironstone Running Node InSpec Controls
# =============================================================================
# Validates a running K3s node AFTER cloud-init completes.
# Run via SSH against a booted node: inspec exec -t ssh://pi@<host>
# =============================================================================

# -----------------------------------------------------------------------------
# User Configuration
# -----------------------------------------------------------------------------
control 'NODE-USER-001' do
  impact 1.0
  title 'Pi user exists'
  desc 'Cloud-init MUST create pi user with sudo privileges'

  describe user('pi') do
    it { should exist }
    its('groups') { should include 'adm' }
    its('groups') { should include 'sudo' }
    its('shell') { should eq '/bin/bash' }
  end
end

control 'NODE-USER-002' do
  impact 1.0
  title 'SSH authorized keys configured'
  desc 'Pi user MUST have SSH keys configured'

  describe file('/home/pi/.ssh/authorized_keys') do
    it { should exist }
    its('content') { should_not be_empty }
  end

  describe directory('/home/pi/.ssh') do
    it { should exist }
    its('mode') { should cmp '0700' }
  end
end

control 'NODE-USER-003' do
  impact 1.0
  title 'Root login disabled'
  desc 'Root account MUST be locked'

  describe shadow.where(user: 'root') do
    its('passwords.first') { should match(/^[!*]/) }
  end
end

# -----------------------------------------------------------------------------
# SSH Security
# -----------------------------------------------------------------------------
control 'NODE-SSH-001' do
  impact 1.0
  title 'SSH password authentication disabled'
  desc 'SSH MUST disable password authentication'

  describe sshd_config do
    its('PasswordAuthentication') { should eq 'no' }
  end
end

control 'NODE-SSH-002' do
  impact 1.0
  title 'SSH root login disabled'
  desc 'SSH MUST disable root login'

  describe sshd_config do
    its('PermitRootLogin') { should eq 'no' }
  end
end

control 'NODE-SSH-003' do
  impact 1.0
  title 'SSH host keys generated'
  desc 'SSH host keys MUST be generated on first boot'

  %w[rsa ecdsa ed25519].each do |type|
    describe file("/etc/ssh/ssh_host_#{type}_key") do
      it { should exist }
      its('mode') { should cmp '0600' }
    end
  end
end

# -----------------------------------------------------------------------------
# System Configuration
# -----------------------------------------------------------------------------
control 'NODE-SYS-001' do
  impact 1.0
  title 'Hostname set from MAC'
  desc 'Hostname MUST match node-[a-f0-9]{6} pattern'

  describe command('hostname') do
    its('stdout.strip') { should match(/^node-[a-f0-9]{6}$/) }
  end
end

control 'NODE-SYS-002' do
  impact 0.7
  title 'Timezone set'
  desc 'Timezone MUST be Europe/London'

  describe command('timedatectl show --property=Timezone --value') do
    its('stdout.strip') { should eq 'Europe/London' }
  end
end

control 'NODE-SYS-003' do
  impact 0.7
  title 'Locale set'
  desc 'Locale MUST be en_GB.UTF-8'

  describe command('locale') do
    its('stdout') { should match(/LANG=en_GB\.UTF-8/) }
  end
end

control 'NODE-SYS-004' do
  impact 1.0
  title 'Swap disabled'
  desc 'Swap MUST be disabled for Kubernetes'

  describe command('swapon --show') do
    its('stdout') { should be_empty }
  end
end

control 'NODE-SYS-005' do
  impact 1.0
  title 'Machine ID generated'
  desc 'Machine ID MUST be generated on first boot'

  describe file('/etc/machine-id') do
    it { should exist }
    its('content') { should match(/\S+/) }
  end
end

# -----------------------------------------------------------------------------
# Kernel Configuration
# -----------------------------------------------------------------------------
control 'NODE-KERNEL-001' do
  impact 1.0
  title 'Overlay module loaded'
  desc 'Overlay kernel module MUST be loaded'

  describe kernel_module('overlay') do
    it { should be_loaded }
  end
end

control 'NODE-KERNEL-002' do
  impact 1.0
  title 'br_netfilter module loaded'
  desc 'br_netfilter kernel module MUST be loaded'

  describe kernel_module('br_netfilter') do
    it { should be_loaded }
  end
end

control 'NODE-KERNEL-003' do
  impact 1.0
  title 'IPv4 forwarding enabled'
  desc 'IPv4 forwarding MUST be enabled'

  describe kernel_parameter('net.ipv4.ip_forward') do
    its('value') { should eq 1 }
  end
end

control 'NODE-KERNEL-004' do
  impact 1.0
  title 'Bridge netfilter enabled'
  desc 'Bridge netfilter MUST be enabled for iptables'

  describe kernel_parameter('net.bridge.bridge-nf-call-iptables') do
    its('value') { should eq 1 }
  end

  describe kernel_parameter('net.bridge.bridge-nf-call-ip6tables') do
    its('value') { should eq 1 }
  end
end

# -----------------------------------------------------------------------------
# Storage Services
# -----------------------------------------------------------------------------
control 'NODE-STORAGE-001' do
  impact 1.0
  title 'iSCSI service running'
  desc 'iSCSI MUST be installed and running for Longhorn'

  describe package('open-iscsi') do
    it { should be_installed }
  end

  describe systemd_service('iscsid') do
    it { should be_enabled }
    it { should be_running }
  end
end

control 'NODE-STORAGE-002' do
  impact 0.7
  title 'Multipath service running'
  desc 'Multipath MUST be installed and running'

  describe package('multipath-tools') do
    it { should be_installed }
  end

  describe systemd_service('multipathd') do
    it { should be_enabled }
    it { should be_running }
  end
end

# -----------------------------------------------------------------------------
# Cloud-Init Status
# -----------------------------------------------------------------------------
control 'NODE-BOOT-001' do
  impact 1.0
  title 'Cloud-init completed'
  desc 'Cloud-init MUST complete successfully'

  describe command('cloud-init status') do
    its('stdout') { should match(/status: done/) }
    its('exit_status') { should eq 0 }
  end
end

control 'NODE-BOOT-002' do
  impact 1.0
  title 'Root filesystem expanded'
  desc 'Root filesystem MUST be expanded'

  describe command("df -h / | tail -1 | awk '{print $2}'") do
    its('stdout.strip') { should_not match(/^[0-3]\./) }
  end
end

# -----------------------------------------------------------------------------
# K3s Service
# -----------------------------------------------------------------------------
control 'NODE-K3S-001' do
  impact 1.0
  title 'K3s service running'
  desc 'K3s service MUST be enabled and running'

  describe systemd_service('k3s') do
    it { should be_enabled }
    it { should be_running }
  end
end

control 'NODE-K3S-002' do
  impact 1.0
  title 'K3s config rendered'
  desc 'K3s config.yaml MUST be rendered from template'

  describe file('/etc/rancher/k3s/config.yaml') do
    it { should exist }
    its('content') { should match(/server:/) }
    its('content') { should match(/cluster-cidr:\s*10\.69\.0\.0\/16/) }
    its('content') { should match(/service-cidr:\s*10\.96\.0\.0\/16/) }
    its('content') { should match(/node-ip:/) }
    its('content') { should_not match(/\$\{K3S_VIP\}/) }
  end
end

control 'NODE-K3S-003' do
  impact 1.0
  title 'K3s token retrieved'
  desc 'K3s cluster token MUST be retrieved from NFS'

  describe file('/etc/rancher/k3s/cluster-token') do
    it { should exist }
    its('mode') { should cmp '0600' }
    its('owner') { should eq 'root' }
  end

  describe command('sudo cat /etc/rancher/k3s/cluster-token | wc -c') do
    its('stdout.strip.to_i') { should be > 0 }
  end
end

control 'NODE-K3S-004' do
  impact 1.0
  title 'K3s registries configured'
  desc 'K3s registry mirrors MUST be configured'

  describe file('/etc/rancher/k3s/registries.yaml') do
    it { should exist }
    its('content') { should match(/mirrors:/) }
    its('content') { should match(/docker\.io:/) }
    its('content') { should match(/ghcr\.io:/) }
  end
end

control 'NODE-K3S-005' do
  impact 1.0
  title 'K3s joining cluster'
  desc 'K3s MUST be connecting to the cluster'

  describe.one do
    describe command('journalctl -u k3s --no-pager -n 500') do
      its('stdout') { should match(/etcdserver/) }
    end
    describe command('journalctl -u k3s --no-pager -n 500') do
      its('stdout') { should match(/Connecting to.*6443/) }
    end
    describe command('journalctl -u k3s --no-pager -n 500') do
      its('stdout') { should match(/Starting k3s/) }
    end
  end
end

# -----------------------------------------------------------------------------
# Cluster Status (requires kubectl access)
# -----------------------------------------------------------------------------
control 'NODE-CLUSTER-001' do
  impact 1.0
  title 'Node is Ready'
  desc 'This node MUST be Ready in the cluster'

  describe command('sudo kubectl get nodes -o wide 2>/dev/null | grep $(hostname)') do
    its('stdout') { should match(/Ready/) }
    its('exit_status') { should eq 0 }
  end
end

control 'NODE-CLUSTER-002' do
  impact 1.0
  title 'Node is control-plane'
  desc 'This node MUST have control-plane role'

  describe command('sudo kubectl get nodes -o wide 2>/dev/null | grep $(hostname)') do
    its('stdout') { should match(/control-plane/) }
  end
end

control 'NODE-CLUSTER-003' do
  impact 1.0
  title 'Etcd member healthy'
  desc 'This node MUST be a healthy etcd member'

  describe command('sudo kubectl get endpoints -n kube-system etcd -o jsonpath="{.subsets[*].addresses[*].ip}" 2>/dev/null') do
    its('exit_status') { should eq 0 }
  end
end

# -----------------------------------------------------------------------------
# Packages (installed by cloud-init)
# -----------------------------------------------------------------------------
control 'NODE-PKG-001' do
  impact 0.7
  title 'Required packages installed'
  desc 'Cloud-init MUST install required packages'

  %w[
    curl
    htop
    iptables
    ipvsadm
    nvme-cli
    open-iscsi
    multipath-tools
    vim
  ].each do |pkg|
    describe package(pkg) do
      it { should be_installed }
    end
  end
end
