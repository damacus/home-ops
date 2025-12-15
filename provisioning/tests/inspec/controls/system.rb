control "system-1.0" do
  impact 1.0
  title "Timezone is set to Europe/London"
  desc "System timezone should be configured correctly"

  describe file("/etc/timezone") do
    its("content") { should match(/Europe\/London/) }
  end

  describe file("/etc/localtime") do
    it { should be_symlink }
    it { should be_linked_to "/usr/share/zoneinfo/Europe/London" }
  end
end

control "system-1.1" do
  impact 1.0
  title "AppArmor service is masked"
  desc "AppArmor should be disabled for Kubernetes compatibility"

  describe systemd_service("apparmor") do
    it { should_not be_enabled }
  end
end

control "system-1.2" do
  impact 0.7
  title "Swap is disabled"
  desc "Kubernetes requires swap to be disabled"

  describe command("cat /proc/swaps | wc -l") do
    its("stdout.strip") { should cmp 1 }  # Only header line
  end
end

control "system-1.3" do
  impact 0.5
  title "Armbian zram swap is disabled"
  desc "Armbian zram swap should be disabled for Kubernetes"

  describe file("/etc/default/armbian-zram-config") do
    its("content") { should match(/^ENABLED=false/) }
  end
end

control "system-1.4" do
  impact 0.7
  title "Machine ID exists"
  desc "Machine ID should exist on a running system"

  describe file("/etc/machine-id") do
    it { should exist }
    its("size") { should be > 0 }
  end
end

control "system-1.5" do
  impact 0.5
  title "Hostname is set"
  desc "Hostname should be set on a running system"

  describe file("/etc/hostname") do
    it { should exist }
  end

  describe command("hostname") do
    its("stdout.strip") { should_not be_empty }
  end
end
