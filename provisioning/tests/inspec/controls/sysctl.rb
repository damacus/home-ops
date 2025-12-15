control "sysctl-1.0" do
  impact 1.0
  title "IP forwarding is enabled"
  desc "IPv4 and IPv6 forwarding required for pod networking"

  describe kernel_parameter("net.ipv4.ip_forward") do
    its("value") { should eq 1 }
  end

  describe kernel_parameter("net.ipv6.conf.all.forwarding") do
    its("value") { should eq 1 }
  end
end

control "sysctl-1.1" do
  impact 1.0
  title "Bridge netfilter is enabled"
  desc "Required for iptables to see bridged traffic"

  describe kernel_parameter("net.bridge.bridge-nf-call-iptables") do
    its("value") { should eq 1 }
  end

  describe kernel_parameter("net.bridge.bridge-nf-call-ip6tables") do
    its("value") { should eq 1 }
  end
end

control "sysctl-1.2" do
  impact 0.7
  title "inotify limits are increased"
  desc "Large clusters require increased inotify limits"

  describe kernel_parameter("fs.inotify.max_user_watches") do
    its("value") { should be >= 524288 }
  end

  describe kernel_parameter("fs.inotify.max_user_instances") do
    its("value") { should be >= 8192 }
  end
end

control "sysctl-1.3" do
  impact 0.7
  title "Sysctl configuration file exists"
  desc "Sysctl settings should persist across reboots"

  describe file("/etc/sysctl.d/99-k8s.conf") do
    it { should exist }
    its("content") { should match(/net\.ipv4\.ip_forward = 1/) }
  end
end
