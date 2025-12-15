control "kernel-1.0" do
  impact 1.0
  title "Required kernel modules are loaded"
  desc "Kubernetes requires specific kernel modules for networking"

  %w[
    br_netfilter
    ip_vs
    ip_vs_rr
    ip_vs_wrr
    ip_vs_sh
    nf_conntrack
  ].each do |mod|
    describe kernel_module(mod) do
      it { should be_loaded }
    end
  end
end

control "kernel-1.3" do
  impact 1.0
  title "Overlay filesystem is available"
  desc "Overlay filesystem required for container storage (may be built-in or module)"

  describe command("cat /proc/filesystems") do
    its("stdout") { should match(/overlay/) }
  end
end

control "kernel-1.1" do
  impact 0.7
  title "iSCSI kernel module is loaded"
  desc "iSCSI module required for Longhorn storage"

  describe kernel_module("iscsi_tcp") do
    it { should be_loaded }
  end
end

control "kernel-1.2" do
  impact 1.0
  title "Kernel modules configuration file exists"
  desc "Modules should be configured to load at boot"

  describe file("/etc/modules-load.d/k8s-modules.conf") do
    it { should exist }
    its("content") { should match(/overlay/) }
    its("content") { should match(/br_netfilter/) }
    its("content") { should match(/ip_vs/) }
  end
end
