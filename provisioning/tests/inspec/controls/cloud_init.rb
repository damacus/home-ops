# frozen_string_literal: true

control 'cloud-init-1.0' do
  impact 1.0
  title 'Cloud-init is installed'
  desc 'Cloud-init should be installed for first-boot configuration'

  describe package('cloud-init') do
    it { should be_installed }
  end
end

control 'cloud-init-1.1' do
  impact 1.0
  title 'Ironstone cloud-init configuration exists'
  desc 'Custom cloud-init config for NoCloud datasource'

  describe file('/etc/cloud/cloud.cfg.d/99-ironstone.cfg') do
    it { should exist }
    its('content') { should match(/datasource_list/) }
    its('content') { should match(/NoCloud/) }
  end
end

control 'cloud-init-1.2' do
  impact 0.7
  title 'Cloud-init state is clean'
  desc 'Cloud-init state should be cleared for first-boot'

  describe directory('/var/lib/cloud/instance') do
    it { should_not exist }
  end

  describe directory('/var/lib/cloud/instances') do
    it { should_not exist }
  end

  describe directory('/var/lib/cloud/data') do
    it { should_not exist }
  end
end

control 'cloud-init-1.3' do
  impact 1.0
  title 'Cloud-init user-data exists in seed directory'
  desc 'NoCloud seed directory should contain user-data'

  describe file('/var/lib/cloud/seed/nocloud/user-data') do
    it { should exist }
    its('content') { should match(/^#cloud-config/) }
  end
end

control 'cloud-init-1.4' do
  impact 1.0
  title 'Cloud-init meta-data exists in seed directory'
  desc 'NoCloud seed directory should contain meta-data with instance-id'

  describe file('/var/lib/cloud/seed/nocloud/meta-data') do
    it { should exist }
    its('content') { should match(/instance-id:/) }
  end
end

control 'cloud-init-1.5' do
  impact 1.0
  title 'Cloud-init user-data has correct K3s VIP'
  desc 'User-data should have K3s VIP templated correctly'

  describe file('/var/lib/cloud/seed/nocloud/user-data') do
    its('content') { should_not match(/__K3S_VIP__/) }
    its('content') { should match(/server:.*192\.168\.1\.200/) }
  end
end

control 'cloud-init-1.6' do
  impact 1.0
  title 'Cloud-init user-data has correct NFS configuration'
  desc 'User-data should have NFS server and share templated correctly'

  describe file('/var/lib/cloud/seed/nocloud/user-data') do
    its('content') { should_not match(/__NFS_SERVER__/) }
    its('content') { should_not match(/__NFS_SHARE__/) }
  end
end
