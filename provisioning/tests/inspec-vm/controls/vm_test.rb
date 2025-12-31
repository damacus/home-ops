# frozen_string_literal: true

control 'vm-1.0' do
  impact 1.0
  title 'Cloud-init completed'
  desc 'Cloud-init should have completed successfully'

  describe command('cloud-init status') do
    its('stdout') { should match(/status: done/) }
  end
end

control 'vm-1.1' do
  impact 1.0
  title 'VM test marker file exists'
  desc 'The VM cloud-init should create a marker file'

  describe file('/home/pi/logs/vm-cloud-init-ok') do
    it { should exist }
    its('content') { should match(/vm cloud-init ok/) }
  end
end

control 'vm-1.2' do
  impact 1.0
  title 'Pi user exists'
  desc 'The pi user should be created by cloud-init'

  describe user('pi') do
    it { should exist }
    its('groups') { should include 'sudo' }
  end
end

control 'vm-1.3' do
  impact 0.7
  title 'NFS client is installed'
  desc 'nfs-common should be installed'

  describe package('nfs-common') do
    it { should be_installed }
  end
end

control 'vm-1.4' do
  impact 0.7
  title 'Timezone is set correctly'
  desc 'Timezone should be Europe/London'

  describe command('timedatectl show --property=Timezone --value') do
    its('stdout.strip') { should eq 'Europe/London' }
  end
end
