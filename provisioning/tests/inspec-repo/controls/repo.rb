control "repo-1.0" do
  impact 1.0
  title "config.env defines required variables"

  config = file("provisioning/config.env")

  describe config do
    it { should exist }
    its("content") { should match(/^NFS_SERVER=/) }
    its("content") { should match(/^NFS_SHARE=/) }
    its("content") { should match(/^K3S_VIP=/) }
    its("content") { should match(/^K3S_VERSION=/) }
    its("content") { should match(/^RPI5_IMAGE_URL=/) }
    its("content") { should match(/^RPI5_IMAGE_SHA256=/) }
    its("content") { should match(/^ROCK5B_IMAGE_URL=/) }
    its("content") { should match(/^ROCK5B_IMAGE_SHA256=/) }
  end
end

control "repo-1.1" do
  impact 1.0
  title "cloud-init user-data is templated (placeholders present)"

  user_data = file("provisioning/cloud-init/user-data.yaml")

  describe user_data do
    it { should exist }
    its("content") { should match(/__K3S_VIP__/) }
    its("content") { should match(/__NFS_SERVER__/) }
    its("content") { should match(/__NFS_SHARE__/) }
  end
end

control "repo-1.2" do
  impact 1.0
  title "build.sh templates user-data and installs bootstrap service"

  build = file("provisioning/build.sh")

  describe build do
    it { should exist }
    its("content") { should match(/__K3S_VIP__/) }
    its("content") { should match(/__NFS_SERVER__/) }
    its("content") { should match(/__NFS_SHARE__/) }
    its("content") { should match(/CLOUD_INIT_DIR\/init\.sh/) }
    its("content") { should match(/CLOUD_INIT_DIR\/init\.service/) }
    its("content") { should match(%r{/usr/local/bin/ironstone-init\.sh}) }
    its("content") { should match(%r{/etc/systemd/system/ironstone-init\.service}) }
  end
end

control "repo-1.3" do
  impact 0.7
  title "make-seed-iso.sh exists and is executable"

  script = file("provisioning/make-seed-iso.sh")

  describe script do
    it { should exist }
    it { should be_executable }
  end
end

control "repo-1.4" do
  impact 1.0
  title "VM cloud-init template exists"

  vm_template = file("provisioning/cloud-init/user-data-vm.yaml")

  describe vm_template do
    it { should exist }
    its("content") { should match(/__K3S_VIP__/) }
    its("content") { should match(/__NFS_SERVER__/) }
    its("content") { should match(/__NFS_SHARE__/) }
  end
end

control "repo-1.5" do
  impact 1.0
  title "make-seed-iso.sh supports --template"

  script = file("provisioning/make-seed-iso.sh")

  describe script do
    its("content") { should match(/--template/) }
  end
end

control "repo-1.6" do
  impact 1.0
  title "vm-test.sh exists for fast VM validation"

  script = file("provisioning/vm-test.sh")

  describe script do
    it { should exist }
    it { should be_executable }
    its("content") { should match(/make-seed-iso\.sh/) }
    its("content") { should match(/user-data-vm\.yaml/) }
  end
end

control "repo-1.7" do
  impact 1.0
  title "inspec-vm profile exists"

  profile = file("provisioning/tests/inspec-vm/inspec.yml")

  describe profile do
    it { should exist }
    its("content") { should match(/^name:/) }
  end
end

control "repo-1.8" do
  impact 1.0
  title "inspec-gold profile exists"

  profile = file("provisioning/tests/inspec-gold/inspec.yml")

  describe profile do
    it { should exist }
    its("content") { should match(/^name:/) }
  end
end

control "repo-1.9" do
  impact 1.0
  title "inspec-running profile exists"

  profile = file("provisioning/tests/inspec-running/inspec.yml")

  describe profile do
    it { should exist }
    its("content") { should match(/^name:/) }
  end
end

control "repo-1.10" do
  impact 0.7
  title "Taskfile includes provisioning:test-cloud-init"

  taskfile = file(".taskfiles/Provisioning/Taskfile.yaml")

  describe taskfile do
    it { should exist }
    its("content") { should match(/test-cloud-init:/) }
  end
end

control "repo-1.11" do
  impact 1.0
  title "test-cloud-init.sh exists for Lima VM testing"

  script = file("provisioning/test-cloud-init.sh")

  describe script do
    it { should exist }
    it { should be_executable }
    its("content") { should match(/inspec-gold/) }
    its("content") { should match(/inspec-running/) }
  end
end

control "repo-1.12" do
  impact 1.0
  title "Requirements file exists with passes tracking"

  requirements = file("provisioning/requirements.json")

  describe requirements do
    it { should exist }
    its("content") { should match(/"requirements"/) }
    its("content") { should match(/"passes"/) }
    its("content") { should match(/"verification"/) }
  end
end
