# =============================================================================
# Ironstone Running System InSpec Controls
# =============================================================================
# These controls validate a running system AFTER cloud-init has completed.
# Requirements mapping: See provisioning/requirements.json test_profiles.running_system
# =============================================================================

# -----------------------------------------------------------------------------
# REQ-USER-001: Pi user created
# -----------------------------------------------------------------------------
control "REQ-USER-001" do
  impact 1.0
  title "Pi user created"
  desc "Cloud-init MUST create a user named 'pi' with sudo privileges"
  tag requirement: "REQ-USER-001"
  tag category: "user"
  tag priority: "critical"

  describe user("pi") do
    it { should exist }
    its("groups") { should include "adm" }
    its("groups") { should include "sudo" }
    its("shell") { should eq "/bin/bash" }
  end
end

# -----------------------------------------------------------------------------
# REQ-USER-002: SSH authorized keys configured
# -----------------------------------------------------------------------------
control "REQ-USER-002" do
  impact 1.0
  title "SSH authorized keys configured"
  desc "The pi user MUST have SSH authorized keys configured"
  tag requirement: "REQ-USER-002"
  tag category: "user"
  tag priority: "critical"

  describe file("/home/pi/.ssh/authorized_keys") do
    it { should exist }
    its("content") { should_not be_empty }
  end

  describe directory("/home/pi/.ssh") do
    it { should exist }
    its("mode") { should cmp "0700" }
  end
end

# -----------------------------------------------------------------------------
# REQ-SSH-001: SSH password authentication disabled
# -----------------------------------------------------------------------------
control "REQ-SSH-001" do
  impact 1.0
  title "SSH password authentication disabled"
  desc "SSH MUST have password authentication disabled for security"
  tag requirement: "REQ-SSH-001"
  tag category: "ssh"
  tag priority: "high"

  describe sshd_config do
    its("PasswordAuthentication") { should eq "no" }
  end
end

# -----------------------------------------------------------------------------
# REQ-SSH-002: SSH root login disabled
# -----------------------------------------------------------------------------
control "REQ-SSH-002" do
  impact 1.0
  title "SSH root login disabled"
  desc "SSH MUST have root login disabled for security"
  tag requirement: "REQ-SSH-002"
  tag category: "ssh"
  tag priority: "high"

  describe sshd_config do
    its("PermitRootLogin") { should eq "no" }
  end
end

# -----------------------------------------------------------------------------
# REQ-SSH-003: SSH host keys generated (running system)
# -----------------------------------------------------------------------------
control "REQ-SSH-003-running" do
  impact 1.0
  title "SSH host keys generated"
  desc "SSH host keys MUST be generated after first boot"
  tag requirement: "REQ-SSH-003"
  tag category: "ssh"
  tag priority: "high"

  %w[rsa ecdsa ed25519].each do |type|
    describe file("/etc/ssh/ssh_host_#{type}_key") do
      it { should exist }
      its("mode") { should cmp "0600" }
    end
  end
end

# -----------------------------------------------------------------------------
# REQ-SYSTEM-002: Hostname set from MAC address
# -----------------------------------------------------------------------------
control "REQ-SYSTEM-002" do
  impact 1.0
  title "Hostname set from MAC address"
  desc "Hostname MUST match pattern 'node-[a-f0-9]{6}' derived from MAC"
  tag requirement: "REQ-SYSTEM-002"
  tag category: "system"
  tag priority: "high"

  describe command("hostname") do
    its("stdout.strip") { should match(/^node-[a-f0-9]{6}$/) }
  end
end

# -----------------------------------------------------------------------------
# REQ-SYSTEM-003: Timezone set to Europe/London
# -----------------------------------------------------------------------------
control "REQ-SYSTEM-003" do
  impact 0.7
  title "Timezone set to Europe/London"
  desc "The system timezone MUST be set to Europe/London"
  tag requirement: "REQ-SYSTEM-003"
  tag category: "system"
  tag priority: "medium"

  describe command("timedatectl show --property=Timezone --value") do
    its("stdout.strip") { should eq "Europe/London" }
  end
end

# -----------------------------------------------------------------------------
# REQ-SYSTEM-004: Locale set to en_GB.UTF-8
# -----------------------------------------------------------------------------
control "REQ-SYSTEM-004" do
  impact 0.7
  title "Locale set to en_GB.UTF-8"
  desc "The system locale MUST be set to en_GB.UTF-8"
  tag requirement: "REQ-SYSTEM-004"
  tag category: "system"
  tag priority: "medium"

  describe command("locale") do
    its("stdout") { should match(/LANG=en_GB\.UTF-8/) }
  end
end

# -----------------------------------------------------------------------------
# REQ-SYSTEM-005: Swap disabled
# -----------------------------------------------------------------------------
control "REQ-SYSTEM-005" do
  impact 1.0
  title "Swap disabled"
  desc "Swap MUST be disabled for Kubernetes compatibility"
  tag requirement: "REQ-SYSTEM-005"
  tag category: "system"
  tag priority: "critical"

  describe command("swapon --show") do
    its("stdout") { should be_empty }
  end
end

# -----------------------------------------------------------------------------
# REQ-KERNEL-001: Overlay kernel module loaded
# -----------------------------------------------------------------------------
control "REQ-KERNEL-001" do
  impact 1.0
  title "Overlay kernel module loaded"
  desc "The overlay kernel module MUST be loaded for container storage"
  tag requirement: "REQ-KERNEL-001"
  tag category: "kernel"
  tag priority: "critical"

  describe kernel_module("overlay") do
    it { should be_loaded }
  end
end

# -----------------------------------------------------------------------------
# REQ-KERNEL-002: br_netfilter kernel module loaded
# -----------------------------------------------------------------------------
control "REQ-KERNEL-002" do
  impact 1.0
  title "br_netfilter kernel module loaded"
  desc "The br_netfilter kernel module MUST be loaded for Kubernetes networking"
  tag requirement: "REQ-KERNEL-002"
  tag category: "kernel"
  tag priority: "critical"

  describe kernel_module("br_netfilter") do
    it { should be_loaded }
  end
end

# -----------------------------------------------------------------------------
# REQ-KERNEL-003: IPv4 forwarding enabled
# -----------------------------------------------------------------------------
control "REQ-KERNEL-003" do
  impact 1.0
  title "IPv4 forwarding enabled"
  desc "IPv4 forwarding MUST be enabled for Kubernetes networking"
  tag requirement: "REQ-KERNEL-003"
  tag category: "kernel"
  tag priority: "critical"

  describe kernel_parameter("net.ipv4.ip_forward") do
    its("value") { should eq 1 }
  end
end

# -----------------------------------------------------------------------------
# REQ-KERNEL-004: Bridge netfilter for iptables enabled
# -----------------------------------------------------------------------------
control "REQ-KERNEL-004" do
  impact 1.0
  title "Bridge netfilter for iptables enabled"
  desc "Bridge netfilter settings MUST be enabled for iptables to see bridged traffic"
  tag requirement: "REQ-KERNEL-004"
  tag category: "kernel"
  tag priority: "critical"

  describe kernel_parameter("net.bridge.bridge-nf-call-iptables") do
    its("value") { should eq 1 }
  end

  describe kernel_parameter("net.bridge.bridge-nf-call-ip6tables") do
    its("value") { should eq 1 }
  end
end

# -----------------------------------------------------------------------------
# REQ-NFS-003: Token file has secure permissions
# -----------------------------------------------------------------------------
control "REQ-NFS-003" do
  impact 1.0
  title "Token file has secure permissions"
  desc "The k3s token file MUST have secure permissions after retrieval"
  tag requirement: "REQ-NFS-003"
  tag category: "nfs"
  tag priority: "critical"

  describe file("/etc/rancher/k3s/token") do
    it { should exist }
    its("mode") { should cmp "0600" }
    its("owner") { should eq "root" }
    its("content") { should_not be_empty }
  end
end

# -----------------------------------------------------------------------------
# REQ-STORAGE-001: iSCSI initiator installed
# -----------------------------------------------------------------------------
control "REQ-STORAGE-001" do
  impact 1.0
  title "iSCSI initiator installed"
  desc "The open-iscsi package MUST be installed for Longhorn storage"
  tag requirement: "REQ-STORAGE-001"
  tag category: "storage"
  tag priority: "high"

  describe package("open-iscsi") do
    it { should be_installed }
  end

  describe systemd_service("iscsid") do
    it { should be_enabled }
    it { should be_running }
  end
end

# -----------------------------------------------------------------------------
# REQ-STORAGE-002: Multipath installed
# -----------------------------------------------------------------------------
control "REQ-STORAGE-002" do
  impact 0.7
  title "Multipath installed"
  desc "The multipath-tools package MUST be installed for storage redundancy"
  tag requirement: "REQ-STORAGE-002"
  tag category: "storage"
  tag priority: "medium"

  describe package("multipath-tools") do
    it { should be_installed }
  end

  describe systemd_service("multipathd") do
    it { should be_enabled }
    it { should be_running }
  end
end

# -----------------------------------------------------------------------------
# REQ-BOOT-001: Cloud-init completes successfully
# -----------------------------------------------------------------------------
control "REQ-BOOT-001" do
  impact 1.0
  title "Cloud-init completes successfully"
  desc "Cloud-init MUST complete successfully on first boot without errors"
  tag requirement: "REQ-BOOT-001"
  tag category: "boot"
  tag priority: "critical"

  describe command("cloud-init status") do
    its("stdout") { should match(/status: done/) }
    its("exit_status") { should eq 0 }
  end
end

# -----------------------------------------------------------------------------
# REQ-BOOT-002: K3s agent joins cluster
# -----------------------------------------------------------------------------
control "REQ-BOOT-002" do
  impact 1.0
  title "K3s agent joins cluster"
  desc "The k3s agent MUST successfully join the cluster after first boot"
  tag requirement: "REQ-BOOT-002"
  tag category: "boot"
  tag priority: "critical"

  describe systemd_service("k3s") do
    it { should be_enabled }
    it { should be_running }
  end

  describe.one do
    describe command("journalctl -u k3s --no-pager -n 500") do
      its("stdout") { should match(/etcdserver/) }
    end
    describe command("journalctl -u k3s --no-pager -n 500") do
      its("stdout") { should match(/Connecting to.*6443/) }
    end
  end
end

# -----------------------------------------------------------------------------
# REQ-BOOT-003: Root filesystem expanded
# -----------------------------------------------------------------------------
control "REQ-BOOT-003" do
  impact 1.0
  title "Root filesystem expanded"
  desc "The root filesystem MUST be expanded to use full disk space on first boot"
  tag requirement: "REQ-BOOT-003"
  tag category: "boot"
  tag priority: "high"

  describe command("df -h / | tail -1 | awk '{print $2}'") do
    its("stdout.strip") { should_not match(/^[0-3]\./) }
  end
end

# -----------------------------------------------------------------------------
# Additional running system checks
# -----------------------------------------------------------------------------
control "RUNNING-MACHINE-ID" do
  impact 1.0
  title "Machine ID is generated"
  desc "Machine ID should be generated on first boot"
  tag category: "system"

  describe file("/etc/machine-id") do
    it { should exist }
    its("size") { should be > 0 }
  end
end
