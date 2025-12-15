control "packages-1.0" do
  impact 1.0
  title "Required packages are installed"
  desc "Essential packages for Kubernetes nodes"

  %w[
    curl
    ca-certificates
    open-iscsi
    nfs-common
    conntrack
    ipvsadm
    socat
  ].each do |pkg|
    describe package(pkg) do
      it { should be_installed }
    end
  end
end

control "packages-1.1" do
  impact 0.7
  title "Python packages for Ansible"
  desc "Python packages required for cluster management"

  %w[
    python3
    python3-apt
    python3-yaml
  ].each do |pkg|
    describe package(pkg) do
      it { should be_installed }
    end
  end
end
