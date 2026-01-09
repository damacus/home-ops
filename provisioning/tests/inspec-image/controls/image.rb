# frozen_string_literal: true

# =============================================================================
# Ironstone Armbian Image InSpec Controls
# =============================================================================
# Validates the Armbian gold image BEFORE first boot.
# Run against a mounted image rootfs or via SSH before cloud-init runs.
# =============================================================================

# -----------------------------------------------------------------------------
# Cloud-Init Configuration
# -----------------------------------------------------------------------------
control 'IMAGE-CLOUD-001' do
  impact 1.0
  title 'Cloud-init package installed'
  desc 'Cloud-init MUST be installed for first-boot configuration'

  describe package('cloud-init') do
    it { should be_installed }
  end
end

control 'IMAGE-CLOUD-002' do
  impact 1.0
  title 'NoCloud datasource configured'
  desc 'Cloud-init MUST use NoCloud datasource for seed data'

  describe file('/etc/cloud/cloud.cfg.d/99-ironstone.cfg') do
    it { should exist }
    its('content') { should match(/datasource_list.*NoCloud/) }
  end
end

control 'IMAGE-CLOUD-003' do
  impact 1.0
  title 'User-data file present'
  desc 'Cloud-init user-data MUST exist with valid configuration'

  describe file('/var/lib/cloud/seed/nocloud/user-data') do
    it { should exist }
    its('content') { should match(/^#cloud-config/) }
    its('content') { should match(/^users:/) }
    its('content') { should match(/^packages:/) }
  end
end

control 'IMAGE-CLOUD-004' do
  impact 1.0
  title 'Meta-data file present'
  desc 'Cloud-init meta-data MUST exist'

  describe file('/var/lib/cloud/seed/nocloud/meta-data') do
    it { should exist }
    its('content') { should match(/instance-id:/) }
  end
end

control 'IMAGE-CLOUD-005' do
  impact 1.0
  title 'Cloud-init state clean'
  desc 'Gold image MUST have clean cloud-init state'

  only_if('Skip on running systems') do
    !file('/var/lib/cloud/instance/boot-finished').exist?
  end

  describe directory('/var/lib/cloud/instance') do
    it { should_not exist }
  end

  describe directory('/var/lib/cloud/instances') do
    it { should_not exist }
  end
end

# -----------------------------------------------------------------------------
# Gold Image State (must be clean for cloning)
# -----------------------------------------------------------------------------
control 'IMAGE-STATE-001' do
  impact 1.0
  title 'Machine ID cleared'
  desc 'Gold image MUST have empty machine-id'

  only_if('Skip on running systems') do
    !file('/var/lib/cloud/instance/boot-finished').exist?
  end

  describe file('/etc/machine-id') do
    it { should exist }
    its('size') { should cmp 0 }
  end
end

control 'IMAGE-STATE-002' do
  impact 1.0
  title 'Hostname cleared'
  desc 'Gold image MUST have empty hostname'

  only_if('Skip on running systems') do
    !file('/var/lib/cloud/instance/boot-finished').exist?
  end

  describe file('/etc/hostname') do
    it { should exist }
    its('content') { should match(/^\s*$/) }
  end
end

control 'IMAGE-STATE-003' do
  impact 1.0
  title 'SSH host keys removed'
  desc 'Gold image MUST NOT contain SSH host keys'

  only_if('Skip on running systems') do
    !file('/var/lib/cloud/instance/boot-finished').exist?
  end

  %w[rsa ecdsa ed25519].each do |type|
    describe file("/etc/ssh/ssh_host_#{type}_key") do
      it { should_not exist }
    end
  end
end

# -----------------------------------------------------------------------------
# K3s Installation
# -----------------------------------------------------------------------------
control 'IMAGE-K3S-001' do
  impact 1.0
  title 'K3s binary installed'
  desc 'K3s binary MUST be present and executable'

  describe file('/usr/local/bin/k3s') do
    it { should exist }
    it { should be_executable }
    its('mode') { should cmp '0755' }
    its('owner') { should eq 'root' }
  end
end

control 'IMAGE-K3S-002' do
  impact 1.0
  title 'K3s symlinks created'
  desc 'kubectl, crictl, ctr symlinks MUST exist'

  %w[kubectl crictl ctr].each do |cmd|
    describe file("/usr/local/bin/#{cmd}") do
      it { should exist }
      it { should be_symlink }
    end

    describe command("readlink /usr/local/bin/#{cmd}") do
      its('stdout') { should match(/k3s/) }
    end
  end
end

control 'IMAGE-K3S-003' do
  impact 1.0
  title 'K3s config template present'
  desc 'K3s config.yaml.template MUST exist for cloud-init rendering'

  describe file('/etc/rancher/k3s/config.yaml.template') do
    it { should exist }
    its('content') { should match(/server:/) }
    its('content') { should match(/\$\{K3S_VIP\}/) }
    its('content') { should match(/token-file:/) }
  end
end

control 'IMAGE-K3S-004' do
  impact 1.0
  title 'K3s systemd service configured'
  desc 'K3s service unit MUST be installed'

  describe file('/etc/systemd/system/k3s.service') do
    it { should exist }
    its('content') { should match(/Type=exec/) }
    its('content') { should match(/k3s server/) }
  end
end

control 'IMAGE-K3S-005' do
  impact 1.0
  title 'K3s init service configured'
  desc 'K3s init service MUST exist for token retrieval'

  describe file('/etc/systemd/system/k3s-init.service') do
    it { should exist }
    its('content') { should match(/k3s-init\.sh/) }
  end
end

control 'IMAGE-K3S-006' do
  impact 1.0
  title 'K3s init script present'
  desc 'K3s init script MUST exist for NFS token retrieval'

  describe file('/usr/local/bin/k3s-init.sh') do
    it { should exist }
    it { should be_executable }
    its('content') { should match(/mount.*nfs/) }
    its('content') { should match(/cluster-token/) }
  end
end

control 'IMAGE-K3S-007' do
  impact 1.0
  title 'Ironstone config present'
  desc 'Build-time config MUST exist for cloud-init templating'

  describe file('/etc/ironstone/config') do
    it { should exist }
    its('content') { should match(/K3S_VIP=/) }
    its('content') { should match(/NFS_SERVER=/) }
    its('content') { should match(/NFS_SHARE=/) }
  end
end

# -----------------------------------------------------------------------------
# System Configuration
# -----------------------------------------------------------------------------
control 'IMAGE-SYS-001' do
  impact 1.0
  title 'Kernel modules configured'
  desc 'K3s kernel modules MUST be configured to load at boot'

  describe file('/etc/modules-load.d/k3s.conf') do
    it { should exist }
    its('content') { should match(/overlay/) }
    its('content') { should match(/br_netfilter/) }
  end
end

control 'IMAGE-SYS-002' do
  impact 1.0
  title 'Sysctl settings configured'
  desc 'K3s sysctl settings MUST be configured'

  describe file('/etc/sysctl.d/99-k3s.conf') do
    it { should exist }
    its('content') { should match(/net\.ipv4\.ip_forward\s*=\s*1/) }
    its('content') { should match(/net\.bridge\.bridge-nf-call-iptables\s*=\s*1/) }
  end
end

control 'IMAGE-SYS-003' do
  impact 1.0
  title 'SSH hardening configured'
  desc 'SSH MUST be hardened'

  describe file('/etc/ssh/sshd_config.d/99-ironstone-hardening.conf') do
    it { should exist }
    its('content') { should match(/PasswordAuthentication\s+no/) }
    its('content') { should match(/PermitRootLogin\s+no/) }
  end
end

control 'IMAGE-SYS-004' do
  impact 1.0
  title 'NFS client installed'
  desc 'NFS client MUST be installed for token retrieval'

  describe package('nfs-common') do
    it { should be_installed }
  end
end

control 'IMAGE-SYS-005' do
  impact 1.0
  title 'Ironstone init script present'
  desc 'Hostname init script MUST exist'

  describe file('/usr/local/bin/ironstone-init.sh') do
    it { should exist }
    it { should be_executable }
    its('content') { should match(/hostnamectl|hostname/) }
  end
end
