control "k3s-1.0" do
  impact 1.0
  title "K3s binary is installed"
  desc "K3s binary should be installed and executable"

  describe file("/usr/local/bin/k3s") do
    it { should exist }
    it { should be_executable }
    its("mode") { should cmp "0755" }
  end
end

control "k3s-1.1" do
  impact 1.0
  title "K3s version is correct"
  desc "K3s should be the expected version"

  describe command("k3s --version") do
    its("stdout") { should match(/v1\.31/) }
    its("exit_status") { should eq 0 }
  end
end

control "k3s-1.2" do
  impact 1.0
  title "K3s init service is enabled"
  desc "k3s-init.service should be enabled to start K3s on first boot"

  describe systemd_service("k3s-init.service") do
    it { should be_enabled }
  end
end

control "k3s-1.3" do
  impact 1.0
  title "K3s service is not enabled"
  desc "k3s.service should NOT be enabled - k3s-init handles startup"

  describe systemd_service("k3s.service") do
    it { should_not be_enabled }
  end
end

control "k3s-1.4" do
  impact 0.7
  title "K3s configuration directory exists"
  desc "K3s config directory should exist for cloud-init to write config"

  describe directory("/etc/rancher/k3s") do
    it { should exist }
    its("mode") { should cmp "0755" }
  end
end
