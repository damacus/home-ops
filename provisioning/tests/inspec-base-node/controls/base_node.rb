# frozen_string_literal: true

control 'base-node-1.0' do
  impact 0.1
  title 'Base node profile loads'

  describe command('true') do
    its('exit_status') { should eq 0 }
  end
end
