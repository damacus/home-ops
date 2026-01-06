# frozen_string_literal: true

control 'storage-longhorn' do
  impact 1.0
  title 'Longhorn Storage is operational'
  desc 'Checks for Longhorn components and StorageClass'

  describe command('kubectl get storageclass longhorn -o jsonpath="{.metadata.name}"') do
    its('stdout') { should eq 'longhorn' }
  end

  describe command('kubectl get pods -n storage -l app.kubernetes.io/name=longhorn --no-headers') do
    its('stdout') { should_not be_empty }
  end
end

control 'storage-openebs' do
  impact 1.0
  title 'OpenEBS is operational'
  desc 'Checks for OpenEBS hostpath StorageClass'

  describe command('kubectl get storageclass openebs-hostpath -o jsonpath="{.metadata.name}"') do
    its('stdout') { should eq 'openebs-hostpath' }
  end

  describe command('kubectl get pods -n openebs-system -l release=openebs --no-headers') do
    its('stdout') { should_not be_empty }
  end
end

control 'storage-volsync' do
  impact 1.0
  title 'VolSync is operational'
  desc 'Checks for VolSync controller'

  describe command('kubectl get pods -n volsync-system -l app.kubernetes.io/name=volsync --no-headers') do
    its('stdout') { should_not be_empty }
  end
end

control 'storage-csi-drivers' do
  impact 0.7
  title 'CSI Drivers are installed'
  desc 'Checks for NFS and SMB CSI drivers'

  describe command('kubectl get pods -n storage -l app.kubernetes.io/name=csi-driver-nfs --no-headers') do
    its('stdout') { should_not be_empty }
  end

  describe command('kubectl get pods -n storage -l app.kubernetes.io/name=csi-driver-smb --no-headers') do
    its('stdout') { should_not be_empty }
  end
end
