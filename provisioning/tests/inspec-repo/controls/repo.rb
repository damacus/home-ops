# frozen_string_literal: true

control 'repo-1.0' do
  impact 1.0
  title 'config.env defines required variables'

  config = file('provisioning/config.env')

  describe config do
    it { should exist }
    its('content') { should match(/^NFS_SERVER=/) }
    its('content') { should match(/^NFS_SHARE=/) }
    its('content') { should match(/^K3S_VIP=/) }
    its('content') { should match(/^K3S_VERSION=/) }
    its('content') { should match(/^RPI5_IMAGE_URL=/) }
    its('content') { should match(/^RPI5_IMAGE_SHA256=/) }
    its('content') { should match(/^ROCK5B_IMAGE_URL=/) }
    its('content') { should match(/^ROCK5B_IMAGE_SHA256=/) }
  end
end

control 'repo-1.1' do
  impact 1.0
  title 'cloud-init user-data is sourced from a Jinja2 template'

  template = file('provisioning/templates/cloud-init/user-data.yaml.j2')

  describe template do
    it { should exist }
    its('content') { should match(/K3S_VIP/) }
    its('content') { should match(/NFS_SERVER/) }
    its('content') { should match(/NFS_SHARE/) }
    its('content') { should match(%r{token-file:\s*/etc/rancher/k3s/cluster-token}) }
    its('content') { should match(%r{https://github\.com/damacus\.keys}) }
    its('content') { should_not match(/ssh_import_id/) }
    its('content') { should match(/^bootcmd:/) }
    its('content') { should match(%r{/usr/local/bin/ironstone-init\.sh}) }
  end
end

control 'repo-1.2' do
  impact 1.0
  title 'build.sh renders templates via makejinja and does not use sed'

  build = file('provisioning/build.sh')

  describe build do
    it { should exist }
    its('content') { should match(/makejinja/) }
    its('content') { should_not match(/sed\s*\\\s*\n\s*-e\s*"s\|__K3S_VIP__/) }
  end
end

control 'repo-1.3' do
  impact 0.7
  title 'make-seed-iso.sh exists and is executable'

  script = file('provisioning/make-seed-iso.sh')

  describe script do
    it { should exist }
    it { should be_executable }
  end
end

control 'repo-1.4' do
  impact 1.0
  title 'VM and production use the same cloud-init template (no user-data-vm.yaml)'

  vm_template = file('provisioning/cloud-init/user-data-vm.yaml')

  describe vm_template do
    it { should_not exist }
  end
end

control 'repo-1.5' do
  impact 1.0
  title 'make-seed-iso.sh renders templates via makejinja'

  script = file('provisioning/make-seed-iso.sh')

  describe script do
    its('content') { should match(/makejinja/) }
    its('content') { should_not match(/sed\s*\\\s*\n\s*-e\s*"s\|__K3S_VIP__/) }
  end
end

control 'repo-1.6' do
  impact 1.0
  title 'vm-test.sh uses the shared template renderer'

  script = file('provisioning/vm-test.sh')

  describe script do
    it { should exist }
    it { should be_executable }
    its('content') { should match(/make-seed-iso\.sh/) }
    its('content') { should_not match(/user-data-vm\.yaml/) }
  end
end

control 'repo-1.7' do
  impact 1.0
  title 'inspec-vm profile exists'

  profile = file('provisioning/tests/inspec-vm/inspec.yml')

  describe profile do
    it { should exist }
    its('content') { should match(/^name:/) }
  end
end

control 'repo-1.9-base-profiles' do
  impact 1.0
  title 'Base InSpec profiles exist for future inheritance'

  base_node = file('provisioning/tests/inspec-base-node/inspec.yml')
  base_k3s = file('provisioning/tests/inspec-base-k3s/inspec.yml')

  describe base_node do
    it { should exist }
    its('content') { should match(/^name:/) }
  end

  describe base_k3s do
    it { should exist }
    its('content') { should match(/^name:/) }
  end
end

control 'repo-1.8' do
  impact 1.0
  title 'inspec-gold profile exists'

  profile = file('provisioning/tests/inspec-gold/inspec.yml')

  describe profile do
    it { should exist }
    its('content') { should match(/^name:/) }
  end
end

control 'repo-1.9' do
  impact 1.0
  title 'inspec-running profile exists'

  profile = file('provisioning/tests/inspec-running/inspec.yml')

  describe profile do
    it { should exist }
    its('content') { should match(/^name:/) }
  end
end

control 'repo-1.10' do
  impact 0.7
  title 'Taskfile includes provisioning:test-cloud-init'

  taskfile = file('.taskfiles/Provisioning/Taskfile.yaml')

  describe taskfile do
    it { should exist }
    its('content') { should match(/test-cloud-init:/) }
  end
end

control 'repo-1.10-audit-alias' do
  impact 0.7
  title 'Provisioning audit task uses inspec-running (not legacy inspec profile)'

  taskfile = file('.taskfiles/Provisioning/Taskfile.yaml')

  describe taskfile do
    it { should exist }
    its('content') { should match(/\n\s{2}audit:\n/) }
    its('content') { should match(%r{\$AUDITOR exec \{\{\.PROVISIONING_DIR\}\}/tests/inspec-running}) }
    its('content') { should_not match(%r{\$AUDITOR exec \{\{\.PROVISIONING_DIR\}\}/tests/inspec(\s|$)}) }
  end
end

control 'repo-1.11' do
  impact 1.0
  title 'test-cloud-init.sh exists for Lima VM testing'

  script = file('provisioning/test-cloud-init.sh')

  describe script do
    it { should exist }
    it { should be_executable }
    its('content') { should match(/inspec-gold/) }
    its('content') { should match(/inspec-running/) }
  end
end

control 'repo-1.12' do
  impact 1.0
  title 'Requirements file exists with passes tracking'

  requirements = file('provisioning/requirements.json')

  describe requirements do
    it { should exist }
    its('content') { should match(/"requirements"/) }
    its('content') { should match(/"passes"/) }
    its('content') { should match(/"verification"/) }
  end
end

control 'repo-1.13' do
  impact 1.0
  title 'Python requirements include Jinja2'

  requirements = file('requirements.txt')

  describe requirements do
    it { should exist }
    its('content') { should match(/^Jinja2==/i) }
  end
end

control 'repo-1.14' do
  impact 1.0
  title 'Python dependencies are managed via uv (requirements.in exists)'

  requirements_in = file('requirements.in')

  describe requirements_in do
    it { should exist }
    its('content') { should match(/^jinja2$/i) }
    its('content') { should match(/^makejinja$/i) }
  end
end

control 'repo-1.15' do
  impact 1.0
  title 'Taskfiles use uv instead of pip'

  workstation = file('.taskfiles/Workstation/Taskfile.yaml')
  ansible = file('.taskfiles/Ansible/Taskfile.yaml')

  describe workstation do
    it { should exist }
    its('content') { should match(/uv venv/) }
    its('content') { should match(/uv pip sync/) }
    its('content') { should_not match(/pip install/) }
  end

  describe ansible do
    it { should exist }
    its('content') { should match(/uv pip (sync|install)/) }
    its('content') { should_not match(/pip install/) }
  end
end

control 'repo-1.16' do
  impact 1.0
  title 'Ansible Python dependencies are managed via uv (ansible/requirements.in exists)'

  requirements_in = file('ansible/requirements.in')

  describe requirements_in do
    it { should exist }
    its('content') { should match(/^ansible$/i) }
    its('content') { should match(/^ansible-lint$/i) }
  end
end

control 'repo-1.17' do
  impact 1.0
  title 'Cloud-init can be re-applied to a running node for fast iteration'

  script = file('provisioning/reapply-cloud-init.sh')
  taskfile = file('.taskfiles/Provisioning/Taskfile.yaml')

  describe script do
    it { should exist }
    it { should be_executable }
    its('content') { should match(/cloud-init clean/) }
    its('content') { should match(/cloud-init status/) }
    its('content') { should match(/reboot/) }
  end

  describe taskfile do
    its('content') { should match(/reapply-cloud-init:/) }
    its('content') { should match(%r{reapply-cloud-init\.sh}) }
  end
end

control 'repo-1.18' do
  impact 1.0
  title 'make-seed-iso.sh can be validated via a local bash harness'

  harness = file('provisioning/tests/harness/make-seed-iso.sh')

  describe harness do
    it { should exist }
    it { should be_executable }
  end

  describe command(harness.path) do
    its('exit_status') { should eq 0 }
  end
end

control 'repo-1.19' do
  impact 0.7
  title 'Provisioning harness tasks exist (no Bats harness)'

  taskfile = file('.taskfiles/Provisioning/Taskfile.yaml')
  harness = file('provisioning/tests/harness/run.sh')

  describe harness do
    it { should exist }
    it { should be_executable }
  end

  describe taskfile do
    its('content') { should match(/test-harness:/) }
    its('content') { should match(%r{tests/harness/run\.sh}) }
    its('content') { should_not match(/test-bats:/) }
  end
end

control 'repo-1.20' do
  impact 0.7
  title 'Provisioning test task uses a bash harness script (no inline bash)'

  taskfile = file('.taskfiles/Provisioning/Taskfile.yaml')
  harness = file('provisioning/tests/harness/inspec-repo.sh')

  describe harness do
    it { should exist }
    it { should be_executable }
  end

  describe taskfile do
    its('content') { should match(/\n\s{2}test:\n\s{4}desc:/) }
    its('content') { should match(%r{\n\s{4}cmd:\s+"\{\{\.PROVISIONING_DIR\}\}/tests/harness/inspec-repo\.sh"}) }
    its('content') { should_not match(/\n\s{2}test:\n\s{4}desc:[^\n]*\n\s{4}cmds:/) }
  end
end

control 'repo-1.21' do
  impact 0.7
  title 'make-seed-iso.sh can render templates without a global makejinja install (uvx fallback)'

  make_seed = file('provisioning/make-seed-iso.sh')

  describe make_seed do
    it { should exist }
    it { should be_executable }
    its('content') { should match(/\buvx\s+makejinja\b/) }
  end
end

control 'repo-1.22' do
  impact 0.7
  title 'reapply-cloud-init.sh uses correct scp port flag (-P)'

  script = file('provisioning/reapply-cloud-init.sh')

  describe script do
    it { should exist }
    it { should be_executable }
    its('content') { should match(/\bscp\b/) }
    its('content') { should match(/\bSCP_BASE=\([\s\S]*-P\s+"\$SSH_PORT"[\s\S]*\)/) }
    its('content') { should match(/\bscp\b\s+"\$\{SCP_BASE\[@\]\}\"/) }
  end
end

control 'repo-1.23' do
  impact 0.7
  title 'reapply-cloud-init.sh does not expand remote STATUS locally (safe quoting)'

  script = file('provisioning/reapply-cloud-init.sh')

  describe script do
    it { should exist }
    it { should be_executable }
    its('content') { should match(/Waiting for cloud-init to complete/) }
    its('content') { should match(/ssh\s+"\$\{SSH_BASE\[@\]\}\"\s+"\$REMOTE"\s+bash\s+-lc\s+'/) }
  end
end

control 'repo-1.24' do
  impact 0.7
  title 'reapply-cloud-init.sh ignores SSH known_hosts for reimage loops'

  script = file('provisioning/reapply-cloud-init.sh')

  describe script do
    it { should exist }
    it { should be_executable }
    its('content') { should match(/StrictHostKeyChecking=no/) }
    its('content') { should match(%r{UserKnownHostsFile=/dev/null}) }
  end
end

control 'repo-1.25' do
  impact 0.7
  title 'Cloud-init template writes k3s config + registries files (readable by audits)'

  template = file('provisioning/templates/cloud-init/user-data.yaml.j2')

  describe template do
    it { should exist }
    its('content') { should match(%r{path:\s*/etc/rancher/k3s/registries\.yaml}) }
    its('content') { should match(%r{path:\s*/etc/rancher/k3s/config\.yaml}) }
    its('content') { should match(%r{path:\s*/etc/rancher/k3s/config\.yaml[\s\S]*?permissions:\s*'0644'}) }
  end
end

control 'repo-1.26' do
  impact 0.7
  title 'reapply-cloud-init.sh waits for SSH before pushing seed files'

  script = file('provisioning/reapply-cloud-init.sh')

  describe script do
    it { should exist }
    it { should be_executable }
    its('content') { should match(/ConnectTimeout=\d+/) }
    its('content') { should match(/Waiting for SSH.*before pushing/i) }
    its('content') { should match(/for _ in \$\(seq 1 \d+\); do[\s\S]*ssh[\s\S]*sleep/) }
    its('content') { should match(/scp\s+"\$\{SCP_BASE\[@\]\}\"/) }
  end
end

control 'repo-1.27' do
  impact 0.7
  title 'Cloud-init template is valid YAML (no unindented document separators)'

  template = file('provisioning/templates/cloud-init/user-data.yaml.j2')

  describe template do
    it { should exist }
    its('content') { should_not match(/(^|\n)---\s*$/) }
  end
end

control 'repo-1.28' do
  impact 0.7
  title 'reapply-cloud-init.sh retries cloud-init wait on transient SSH failures'

  script = file('provisioning/reapply-cloud-init.sh')

  describe script do
    it { should exist }
    it { should be_executable }
    its('content') { should match(/Waiting for cloud-init to complete/) }
    its('content') { should match(/CLOUD_INIT_OK=/) }
    its('content') { should match(/for _ in \$\(seq 1 \d+\); do[\s\S]*bash -lc[\s\S]*sleep/) }
  end
end

control 'repo-1.29' do
  impact 0.7
  title 'K3s files are managed via cloud-init write_files (k3s-init does not overwrite them)'

  template = file('provisioning/templates/cloud-init/user-data.yaml.j2')

  describe template do
    it { should exist }
    its('content') { should match(%r{path:\s*/etc/rancher/k3s/config\.yaml}) }
    its('content') { should match(%r{path:\s*/etc/rancher/k3s/registries\.yaml}) }
    its('content') { should_not match(%r{(?<!>)>\s*/etc/rancher/k3s/config\.yaml}) }
    its('content') { should_not match(%r{(?<!>)>\s*/etc/rancher/k3s/registries\.yaml}) }
  end
end

control 'repo-1.30' do
  impact 0.7
  title 'K3s runs as stock systemd service (no k3s-init wrapper)'

  template = file('provisioning/templates/cloud-init/user-data.yaml.j2')

  describe template do
    it { should exist }

    its('content') { should match(%r{path:\s*/etc/systemd/system/k3s\.service}) }
    its('content') { should_not match(%r{ExecStart=/usr/local/bin/k3s-init\.sh}) }
    its('content') { should match(%r{ExecStart=/usr/local/bin/k3s\s+}) }
    its('content') { should_not match(%r{path:\s*/usr/local/bin/k3s-init\.sh}) }
  end
end

control 'repo-1.31' do
  impact 0.7
  title 'K3s service runs in server mode'

  template = file('provisioning/templates/cloud-init/user-data.yaml.j2')

  describe template do
    it { should exist }

    its('content') { should match(%r{ExecStart=/usr/local/bin/k3s\s+server\b}) }
    its('content') { should_not match(%r{ExecStart=/usr/local/bin/k3s\s+agent\b}) }
  end
end
