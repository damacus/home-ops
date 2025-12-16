# frozen_string_literal: true

control 'nfs-1.0' do
  impact 1.0
  title 'NFS client packages are installed'
  desc 'nfs-common should be installed for NFS token retrieval'

  describe package('nfs-common') do
    it { should be_installed }
  end
end

control 'nfs-1.1' do
  impact 1.0
  title 'K3s init script exists'
  desc 'k3s-init.sh should exist and be executable'

  describe file('/usr/local/bin/k3s-init.sh') do
    it { should exist }
    it { should be_executable }
    its('mode') { should cmp '0755' }
  end
end

control 'nfs-1.2' do
  impact 1.0
  title 'K3s init script contains NFS configuration'
  desc 'k3s-init.sh should have NFS server and share configured'

  describe file('/usr/local/bin/k3s-init.sh') do
    its('content') { should match(/NFS_SERVER=/) }
    its('content') { should match(/NFS_SHARE=/) }
    its('content') { should match(/TOKEN_PATH=/) }
  end
end

control 'nfs-1.3' do
  impact 1.0
  title 'K3s init script mounts NFS with correct options'
  desc 'NFS mount should use safe options (ro, nolock, soft, timeout)'

  describe file('/usr/local/bin/k3s-init.sh') do
    its('content') { should match(/mount -t nfs.*ro/) }
    its('content') { should match(/nolock/) }
    its('content') { should match(/soft/) }
  end
end

control 'nfs-1.4' do
  impact 1.0
  title 'K3s init script handles missing token gracefully'
  desc 'Script should exit with error if token not found on NFS'

  describe file('/usr/local/bin/k3s-init.sh') do
    its('content') { should match(/ERROR.*Token not found/) }
    its('content') { should match(/exit 1/) }
  end
end

control 'nfs-1.5' do
  impact 1.0
  title 'K3s init script skips NFS if token exists'
  desc 'Script should not mount NFS if token already present'

  describe file('/usr/local/bin/k3s-init.sh') do
    its('content') { should match(%r{if.*-f.*/etc/rancher/k3s/token}) }
    its('content') { should match(/skipping NFS fetch/i) }
  end
end

control 'nfs-1.6' do
  impact 1.0
  title 'K3s token file has secure permissions'
  desc 'Token file should be created with 0600 permissions'

  describe file('/usr/local/bin/k3s-init.sh') do
    its('content') { should match(/chmod 600.*token/) }
  end
end
