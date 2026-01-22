# frozen_string_literal: true

title 'Grafana OIDC Authentication Tests'

control 'grafana-oidc-config' do
  impact 1.0
  title 'Verify Grafana OIDC configuration'
  desc 'Ensure Grafana is configured to use Zitadel OIDC authentication'

  describe http('https://grafana.ironstone.casa',
                enable_remote_worker: true,
                max_redirects: 0) do
    its('status') { should be_in [200, 302] }
  end

  describe http('https://grafana.ironstone.casa/login',
                enable_remote_worker: true,
                max_redirects: 0) do
    its('status') { should be_in [200, 302] }
    its('body') { should match(/Zitadel|Sign in with Zitadel/i) }
  end
end

control 'grafana-oidc-secret' do
  impact 1.0
  title 'Verify Grafana OIDC secret exists'
  desc 'Ensure the zitadel-grafana-oidc secret is created and contains required keys'

  describe command('kubectl get secret zitadel-grafana-oidc -n authentication -o json') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/"client-id"/) }
    its('stdout') { should match(/"client-secret"/) }
  end

  describe command('kubectl get secret zitadel-grafana-oidc -n authentication -o jsonpath="{.data.client-id}" | base64 -d') do
    its('exit_status') { should eq 0 }
    its('stdout') { should_not be_empty }
  end

  describe command('kubectl get secret zitadel-grafana-oidc -n authentication -o jsonpath="{.data.client-secret}" | base64 -d') do
    its('exit_status') { should eq 0 }
    its('stdout') { should_not be_empty }
  end
end

control 'grafana-oidc-endpoints' do
  impact 1.0
  title 'Verify Zitadel OIDC endpoints are accessible'
  desc 'Ensure Zitadel OIDC discovery endpoint is accessible'

  describe http('https://zitadel.damacus.io/.well-known/openid-configuration',
                enable_remote_worker: true) do
    its('status') { should eq 200 }
    its('headers.Content-Type') { should match(/application\/json/) }
    its('body') { should match(/"issuer"/) }
    its('body') { should match(/"authorization_endpoint"/) }
    its('body') { should match(/"token_endpoint"/) }
    its('body') { should match(/"userinfo_endpoint"/) }
  end
end
