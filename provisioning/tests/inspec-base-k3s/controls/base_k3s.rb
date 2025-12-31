# frozen_string_literal: true

control 'base-k3s-1.0' do
  impact 0.1
  title 'Base k3s profile loads'

  describe command('true') do
    its('exit_status') { should eq 0 }
  end
end
