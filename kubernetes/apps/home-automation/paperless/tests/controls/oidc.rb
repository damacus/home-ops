# frozen_string_literal: true

title 'Paperless OIDC Authentication Tests'

control 'paperless-oidc-config' do
  impact 1.0
  title 'Verify Paperless OIDC configuration'
  desc 'Ensure Paperless is configured to use Zitadel OIDC authentication'

  describe http('https://paperless.ironstone.casa',
                enable_remote_worker: true,
                max_redirects: 0) do
    its('status') { should be_in [200, 302] }
  end

  describe http('https://paperless.ironstone.casa/accounts/login/',
                enable_remote_worker: true,
                max_redirects: 0) do
    its('status') { should be_in [200, 302] }
    its('body') { should match(/Zitadel|Sign in with Zitadel/i) }
  end
end

control 'paperless-oidc-secret' do
  impact 1.0
  title 'Verify Paperless OIDC secret exists'
  desc 'Ensure the paperless-zitadel-oidc secret is created and contains required keys'

  describe command('kubectl get secret paperless-zitadel-oidc -n home-automation -o json') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/"client-id"/) }
    its('stdout') { should match(/"client-secret"/) }
    its('stdout') { should match(/"providers"/) }
  end

  describe command('kubectl get secret paperless-zitadel-oidc -n home-automation -o jsonpath="{.data.client-id}" | base64 -d') do
    its('exit_status') { should eq 0 }
    its('stdout') { should_not be_empty }
  end

  describe command('kubectl get secret paperless-zitadel-oidc -n home-automation -o jsonpath="{.data.providers}" | base64 -d') do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/zitadel/) }
    its('stdout') { should match(/openid_connect/) }
  end
end

control 'paperless-oidc-endpoints' do
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
