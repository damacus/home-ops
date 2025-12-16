# =============================================================================
# Ironstone Gold Image InSpec Controls
# =============================================================================
# These controls validate a gold master image BEFORE first boot.
# Requirements mapping: See provisioning/requirements.json test_profiles.gold_image
# =============================================================================

control "REQ-CLOUD-001" do
  impact 1.0
  title "Cloud-init package installed"
  desc "The cloud-init package MUST be installed on the gold image"
  tag requirement: "REQ-CLOUD-001"
  tag category: "cloud-init"
  tag priority: "critical"

  describe package("cloud-init") do
    it { should be_installed }
  end
end

# -----------------------------------------------------------------------------
# REQ-CLOUD-002: NoCloud datasource configured
# -----------------------------------------------------------------------------
control "REQ-CLOUD-002" do
  impact 1.0
  title "NoCloud datasource configured"
  desc "Cloud-init MUST be configured to use the NoCloud datasource"
  tag requirement: "REQ-CLOUD-002"
  tag category: "cloud-init"
  tag priority: "critical"

  describe file("/etc/cloud/cloud.cfg.d/99-ironstone.cfg") do
    it { should exist }
    its("content") { should match(/datasource_list.*NoCloud/) }
  end
end

# -----------------------------------------------------------------------------
# REQ-CLOUD-003: User-data file present
# -----------------------------------------------------------------------------
control "REQ-CLOUD-003" do
  impact 1.0
  title "User-data file present"
  desc "The user-data file MUST exist and contain valid cloud-init configuration"
  tag requirement: "REQ-CLOUD-003"
  tag category: "cloud-init"
  tag priority: "critical"

  describe file("/var/lib/cloud/seed/nocloud/user-data") do
    it { should exist }
    its("content") { should match(/^#cloud-config/) }
    its("content") { should_not match(/__K3S_VIP__/) }
    its("content") { should_not match(/__NFS_SERVER__/) }
    its("content") { should_not match(/__NFS_SHARE__/) }
  end
end

# -----------------------------------------------------------------------------
# REQ-CLOUD-004: Meta-data file present
# -----------------------------------------------------------------------------
control "REQ-CLOUD-004" do
  impact 1.0
  title "Meta-data file present"
  desc "The meta-data file MUST exist at /var/lib/cloud/seed/nocloud/meta-data"
  tag requirement: "REQ-CLOUD-004"
  tag category: "cloud-init"
  tag priority: "critical"

  describe file("/var/lib/cloud/seed/nocloud/meta-data") do
    it { should exist }
    its("content") { should match(/instance-id:/) }
  end
end

# -----------------------------------------------------------------------------
# REQ-CLOUD-005: Cloud-init state clean on gold image
# -----------------------------------------------------------------------------
control "REQ-CLOUD-005" do
  impact 1.0
  title "Cloud-init state clean on gold image"
  desc "The gold image MUST have clean cloud-init state so it runs on first boot"
  tag requirement: "REQ-CLOUD-005"
  tag category: "cloud-init"
  tag priority: "critical"

  describe directory("/var/lib/cloud/instance") do
    it { should_not exist }
  end

  describe directory("/var/lib/cloud/instances") do
    it { should_not exist }
  end

  describe directory("/var/lib/cloud/data") do
    it { should_not exist }
  end
end

# -----------------------------------------------------------------------------
# REQ-SSH-003: SSH host keys removed on gold image
# -----------------------------------------------------------------------------
control "REQ-SSH-003-gold" do
  impact 1.0
  title "SSH host keys removed on gold image"
  desc "The gold image MUST NOT contain SSH host keys"
  tag requirement: "REQ-SSH-003"
  tag category: "ssh"
  tag priority: "high"

  %w[rsa ecdsa ed25519].each do |type|
    describe file("/etc/ssh/ssh_host_#{type}_key") do
      it { should_not exist }
    end
  end
end

# -----------------------------------------------------------------------------
# REQ-SYSTEM-001: Machine ID cleared on gold image
# -----------------------------------------------------------------------------
control "REQ-SYSTEM-001-gold" do
  impact 1.0
  title "Machine ID cleared on gold image"
  desc "The gold image MUST have /etc/machine-id empty or cleared"
  tag requirement: "REQ-SYSTEM-001"
  tag category: "system"
  tag priority: "high"

  describe file("/etc/machine-id") do
    it { should exist }
    its("size") { should cmp 0 }
  end
end

# -----------------------------------------------------------------------------
# REQ-SYSTEM-002-gold: Hostname cleared on gold image
# -----------------------------------------------------------------------------
control "REQ-SYSTEM-002-gold" do
  impact 1.0
  title "Hostname cleared on gold image"
  desc "The gold image MUST have hostname cleared"
  tag requirement: "REQ-SYSTEM-002"
  tag category: "system"
  tag priority: "high"

  describe file("/etc/hostname") do
    it { should exist }
    its("content") { should match(/^\s*$/) }
  end
end

# -----------------------------------------------------------------------------
# REQ-K3S-001: K3s binary installed
# -----------------------------------------------------------------------------
control "REQ-K3S-001" do
  impact 1.0
  title "K3s binary installed"
  desc "The k3s binary MUST be installed at /usr/local/bin/k3s and be executable"
  tag requirement: "REQ-K3S-001"
  tag category: "k3s"
  tag priority: "critical"

  describe file("/usr/local/bin/k3s") do
    it { should exist }
    it { should be_executable }
    its("mode") { should cmp "0755" }
    its("owner") { should eq "root" }
  end
end

# -----------------------------------------------------------------------------
# REQ-K3S-002: K3s symlinks created
# -----------------------------------------------------------------------------
control "REQ-K3S-002" do
  impact 1.0
  title "K3s symlinks created"
  desc "K3s symlinks for kubectl, crictl, and ctr MUST exist"
  tag requirement: "REQ-K3S-002"
  tag category: "k3s"
  tag priority: "high"

  %w[kubectl crictl ctr].each do |cmd|
    describe file("/usr/local/bin/#{cmd}") do
      it { should exist }
      it { should be_symlink }
      it { should be_linked_to "k3s" }
    end
  end
end

# -----------------------------------------------------------------------------
# REQ-K3S-003: K3s configuration file present
# -----------------------------------------------------------------------------
control "REQ-K3S-003" do
  impact 1.0
  title "K3s configuration file present"
  desc "The k3s config.yaml MUST exist with correct server and token-file settings"
  tag requirement: "REQ-K3S-003"
  tag category: "k3s"
  tag priority: "critical"

  describe file("/etc/rancher/k3s/config.yaml") do
    it { should exist }
    its("content") { should match(/server:/) }
    its("content") { should match(/token-file:/) }
  end

  describe directory("/etc/rancher/k3s") do
    it { should exist }
  end
end

# -----------------------------------------------------------------------------
# REQ-K3S-004: K3s systemd service configured
# -----------------------------------------------------------------------------
control "REQ-K3S-004" do
  impact 1.0
  title "K3s systemd service configured"
  desc "The k3s.service systemd unit MUST be installed"
  tag requirement: "REQ-K3S-004"
  tag category: "k3s"
  tag priority: "critical"

  describe file("/etc/systemd/system/k3s.service") do
    it { should exist }
    its("content") { should match(/Type=exec/) }
    its("content") { should match(/k3s-init\.sh/) }
  end
end

# -----------------------------------------------------------------------------
# REQ-K3S-005: K3s init script present
# -----------------------------------------------------------------------------
control "REQ-K3S-005" do
  impact 1.0
  title "K3s init script present"
  desc "The k3s-init.sh script MUST exist to handle NFS token retrieval"
  tag requirement: "REQ-K3S-005"
  tag category: "k3s"
  tag priority: "critical"

  describe file("/usr/local/bin/k3s-init.sh") do
    it { should exist }
    it { should be_executable }
    its("mode") { should cmp "0755" }
    its("content") { should match(/mount.*nfs/) }
    its("content") { should match(/token/) }
  end
end

# -----------------------------------------------------------------------------
# REQ-NFS-001: NFS client installed
# -----------------------------------------------------------------------------
control "REQ-NFS-001" do
  impact 1.0
  title "NFS client installed"
  desc "The nfs-common package MUST be installed for NFS token retrieval"
  tag requirement: "REQ-NFS-001"
  tag category: "nfs"
  tag priority: "critical"

  describe package("nfs-common") do
    it { should be_installed }
  end
end

# -----------------------------------------------------------------------------
# REQ-NFS-002: NFS mount uses safe options
# -----------------------------------------------------------------------------
control "REQ-NFS-002" do
  impact 1.0
  title "NFS mount uses safe options"
  desc "The NFS mount in k3s-init.sh MUST use safe mount options"
  tag requirement: "REQ-NFS-002"
  tag category: "nfs"
  tag priority: "high"

  describe file("/usr/local/bin/k3s-init.sh") do
    its("content") { should match(/mount.*-o.*ro/) }
    its("content") { should match(/soft/) }
  end
end

# -----------------------------------------------------------------------------
# REQ-INIT-001: Ironstone init service installed
# -----------------------------------------------------------------------------
control "REQ-INIT-001" do
  impact 1.0
  title "Ironstone init service installed"
  desc "The ironstone-init.service MUST be installed to set hostname from MAC"
  tag requirement: "REQ-INIT-001"
  tag category: "init"
  tag priority: "high"

  describe file("/etc/systemd/system/ironstone-init.service") do
    it { should exist }
    its("content") { should match(/Before=cloud-init/) }
  end
end

# -----------------------------------------------------------------------------
# REQ-INIT-002: Ironstone init script installed
# -----------------------------------------------------------------------------
control "REQ-INIT-002" do
  impact 1.0
  title "Ironstone init script installed"
  desc "The ironstone-init.sh script MUST be installed to derive hostname from MAC"
  tag requirement: "REQ-INIT-002"
  tag category: "init"
  tag priority: "high"

  describe file("/usr/local/bin/ironstone-init.sh") do
    it { should exist }
    it { should be_executable }
    its("content") { should match(/hostnamectl|hostname/) }
  end
end

# -----------------------------------------------------------------------------
# Additional gold image checks (kernel modules config, sysctl config)
# -----------------------------------------------------------------------------
control "GOLD-KERNEL-CONFIG" do
  impact 1.0
  title "Kernel modules configuration exists"
  desc "Kubernetes kernel modules should be configured to load at boot"
  tag category: "kernel"

  describe file("/etc/modules-load.d/k8s-modules.conf") do
    it { should exist }
    its("content") { should match(/overlay/) }
    its("content") { should match(/br_netfilter/) }
  end
end

control "GOLD-SYSCTL-CONFIG" do
  impact 1.0
  title "Sysctl settings for Kubernetes exist"
  desc "Kubernetes sysctl settings should be configured"
  tag category: "system"

  describe file("/etc/sysctl.d/99-k8s.conf") do
    it { should exist }
    its("content") { should match(/net\.ipv4\.ip_forward\s*=\s*1/) }
    its("content") { should match(/net\.ipv6\.conf\.all\.forwarding\s*=\s*1/) }
  end
end

control "GOLD-SSH-HARDENING" do
  impact 1.0
  title "SSH hardening configuration exists"
  desc "SSH should be hardened with secure settings"
  tag category: "ssh"

  describe file("/etc/ssh/sshd_config.d/99-harden.conf") do
    it { should exist }
    its("content") { should match(/PasswordAuthentication no/) }
    its("content") { should match(/PermitRootLogin no/) }
  end
end
