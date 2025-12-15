control "cloud-init-1.0" do
  impact 1.0
  title "Cloud-init is installed"
  desc "Cloud-init should be installed for first-boot configuration"

  describe package("cloud-init") do
    it { should be_installed }
  end
end

control "cloud-init-1.1" do
  impact 1.0
  title "Ironstone cloud-init configuration exists"
  desc "Custom cloud-init config for Matchbox datasource"

  describe file("/etc/cloud/cloud.cfg.d/99-ironstone.cfg") do
    it { should exist }
    its("content") { should match(/datasource_list/) }
  end
end

control "cloud-init-1.2" do
  impact 0.7
  title "Cloud-init state is clean"
  desc "Cloud-init state should be cleared for first-boot"

  describe directory("/var/lib/cloud/instance") do
    it { should_not exist }
  end

  describe directory("/var/lib/cloud/instances") do
    it { should_not exist }
  end
end
