# frozen_string_literal: true

control 'k3s-1.0' do
  impact 1.0
  title 'K3s binary is installed'
  desc 'K3s binary should be installed and executable'

  describe file('/usr/local/bin/k3s') do
    it { should exist }
    it { should be_executable }
    its('mode') { should cmp '0755' }
  end
end

control 'k3s-1.1' do
  impact 1.0
  title 'K3s version is correct'
  desc 'K3s should be the expected version'

  describe command('k3s --version') do
    its('stdout') { should match(/v1\.31/) }
    its('exit_status') { should eq 0 }
  end
end

control 'k3s-1.2' do
  impact 1.0
  title 'K3s symlinks are created'
  desc 'kubectl, crictl, and ctr should be symlinks to k3s'

  describe file('/usr/local/bin/kubectl') do
    it { should exist }
    it { should be_symlink }
    it { should be_linked_to 'k3s' }
  end

  describe file('/usr/local/bin/crictl') do
    it { should exist }
    it { should be_symlink }
    it { should be_linked_to 'k3s' }
  end

  describe file('/usr/local/bin/ctr') do
    it { should exist }
    it { should be_symlink }
    it { should be_linked_to 'k3s' }
  end
end

control 'k3s-1.3' do
  impact 0.7
  title 'K3s configuration directory exists'
  desc 'K3s config directory should exist for cloud-init to write config'

  describe directory('/etc/rancher/k3s') do
    it { should exist }
    its('mode') { should cmp '0755' }
  end
end

control 'k3s-1.4' do
  impact 1.0
  title 'K3s config.yaml is present'
  desc 'K3s config should be written by cloud-init'

  describe file('/etc/rancher/k3s/config.yaml') do
    it { should exist }
    its('mode') { should cmp '0600' }
    its('content') { should match(/server:/) }
    its('content') { should match(/token-file:/) }
  end
end

control 'k3s-1.5' do
  impact 1.0
  title 'K3s service file is installed'
  desc 'k3s.service should be installed for systemd management'

  describe file('/etc/systemd/system/k3s.service') do
    it { should exist }
    its('content') { should match(/Type=exec/) }
    its('content') { should match(/k3s-init\.sh/) }
  end
end

control 'k3s-1.6' do
  impact 1.0
  title 'K3s service is enabled'
  desc 'k3s.service should be enabled to start on boot'

  describe systemd_service('k3s.service') do
    it { should be_enabled }
  end
end
