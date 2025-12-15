control "users-1.0" do
  impact 1.0
  title "Pi user exists"
  desc "The pi user should exist for SSH access"

  describe user("pi") do
    it { should exist }
    its("uid") { should eq 1000 }
    its("groups") { should include "sudo" }
    its("home") { should eq "/home/pi" }
    its("shell") { should eq "/bin/bash" }
  end
end

control "users-1.1" do
  impact 0.7
  title "Pi user home directory exists"
  desc "Pi user should have a home directory"

  describe directory("/home/pi") do
    it { should exist }
    its("owner") { should eq "pi" }
  end
end

control "users-1.2" do
  impact 1.0
  title "Root user exists"
  desc "Root user should exist"

  describe user("root") do
    it { should exist }
    its("uid") { should eq 0 }
  end
end
