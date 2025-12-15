control "security-1.0" do
  impact 1.0
  title "SSH host keys exist and have correct permissions"
  desc "SSH host keys should exist on a running system with secure permissions"

  %w[
    /etc/ssh/ssh_host_rsa_key
    /etc/ssh/ssh_host_ecdsa_key
    /etc/ssh/ssh_host_ed25519_key
  ].each do |keyfile|
    describe file(keyfile) do
      it { should exist }
      its("mode") { should cmp "0600" }
    end
  end
end

control "security-1.1" do
  impact 0.7
  title "No bash history"
  desc "Bash history should be cleared for security"

  describe file("/root/.bash_history") do
    it { should_not exist }
  end
end
