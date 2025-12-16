# frozen_string_literal: true

control 'security-1.0' do
  impact 1.0
  title 'SSH hardening configuration exists'
  desc 'SSH should be hardened with secure settings'

  describe file('/etc/ssh/sshd_config.d/99-harden.conf') do
    it { should exist }
    its('content') { should match(/PasswordAuthentication no/) }
    its('content') { should match(/PermitRootLogin no/) }
    its('content') { should match(/AuthenticationMethods publickey/) }
  end
end

control 'security-1.1' do
  impact 0.7
  title 'No bash history'
  desc 'Bash history should be cleared for security'

  describe file('/root/.bash_history') do
    it { should_not exist }
  end
end

control 'security-1.2' do
  impact 1.0
  title 'SSH host keys removed for gold image'
  desc 'SSH host keys should be removed so they regenerate on first boot'
  tag 'gold-image-only'

  %w[
    /etc/ssh/ssh_host_rsa_key
    /etc/ssh/ssh_host_ecdsa_key
    /etc/ssh/ssh_host_ed25519_key
  ].each do |keyfile|
    describe file(keyfile) do
      it { should_not exist }
    end
  end
end

control 'security-1.3' do
  impact 1.0
  title 'Machine ID cleared for gold image'
  desc 'Machine ID should be empty so it regenerates on first boot'
  tag 'gold-image-only'

  describe file('/etc/machine-id') do
    it { should exist }
    its('size') { should cmp 0 }
  end
end
