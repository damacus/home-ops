# frozen_string_literal: true

title 'Mealie OIDC Authentication Tests'

control 'mealie-oidc-config' do
  impact 1.0
  title 'Verify Mealie OIDC configuration'
  desc 'Ensure Mealie is configured to use Zitadel OIDC authentication'

  describe http('https://mealie.ironstone.casa',
                enable_remote_worker: true,
                max_redirects: 0) do
    its('status') { should be_in [200, 302] }
  end

  describe http('https://mealie.ironstone.casa/login',
                enable_remote_worker: true,
                max_redirects: 0) do
    its('status') { should be_in [200, 302] }
    its('body') { should match(/Zitadel|Sign in with Zitadel/i) }
  end
end

control 'mealie-oidc-secret' do
  impact 1.0
  title 'Verify Mealie OIDC secret exists'
  desc 'Ensure the mealie-zitadel-oidc secret is created and contains required keys'

  describe command('kubectl get secret mealie-zitadel-oidc -n home -o json') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/"client-id"/) }
  end

  describe command('kubectl get secret mealie-zitadel-oidc -n home -o jsonpath="{.data.client-id}" | base64 -d') do
    its('exit_status') { should eq 0 }
    its('stdout') { should_not be_empty }
  end
end

control 'mealie-oidc-endpoints' do
  impact 1.0
  title 'Verify Zitadel OIDC endpoints are accessible'
  desc 'Ensure Zitadel OIDC discovery endpoint is accessible'

  describe http('https://zitadel.ironstone.casa/.well-known/openid-configuration',
                enable_remote_worker: true) do
    its('status') { should eq 200 }
    its('headers.Content-Type') { should match(/application\/json/) }
    its('body') { should match(/"issuer"/) }
    its('body') { should match(/"authorization_endpoint"/) }
    its('body') { should match(/"token_endpoint"/) }
  end
end

control 'mealie-oidc-api-endpoint' do
  impact 1.0
  title 'Verify Mealie OIDC callback endpoint'
  desc 'Ensure Mealie OIDC callback endpoint is accessible'

  describe http('https://mealie.ironstone.casa/api/auth/oauth/callback',
                enable_remote_worker: true,
                max_redirects: 0) do
    its('status') { should be_in [200, 302, 400, 405] }
  end
end
