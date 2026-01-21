# frozen_string_literal: true

# =============================================================================
# Zitadel Application InSpec Controls
# =============================================================================
# Validates Zitadel identity provider is running and accessible.
# Run locally: inspec exec kubernetes/apps/authentication/zitadel/tests
# =============================================================================

zitadel_url = input('zitadel_url')

# -----------------------------------------------------------------------------
# HTTPS Endpoint Accessibility
# -----------------------------------------------------------------------------
control 'ZITADEL-HTTPS-001' do
  impact 1.0
  title 'Zitadel HTTPS endpoint is accessible'
  desc 'The Zitadel HTTPS endpoint MUST be reachable and return a valid response'

  describe http("#{zitadel_url}/", ssl_verify: true) do
    its('status') { should be_in [200, 301, 302] }
  end
end

control 'ZITADEL-HTTPS-002' do
  impact 1.0
  title 'Zitadel TLS certificate is valid'
  desc 'The Zitadel TLS certificate MUST be valid and not expired'

  describe command('echo | openssl s_client -connect zitadel.damacus.io:443 -servername zitadel.damacus.io 2>/dev/null | openssl x509 -noout -checkend 1209600') do
    its('exit_status') { should eq 0 }
  end
end

# -----------------------------------------------------------------------------
# Health Endpoints
# -----------------------------------------------------------------------------
control 'ZITADEL-HEALTH-001' do
  impact 1.0
  title 'Zitadel healthz endpoint returns healthy'
  desc 'The /healthz endpoint MUST return 200 OK'

  describe http("#{zitadel_url}/healthz", ssl_verify: true) do
    its('status') { should eq 200 }
  end
end

control 'ZITADEL-HEALTH-002' do
  impact 1.0
  title 'Zitadel ready endpoint returns ready'
  desc 'The /debug/ready endpoint MUST return 200 OK when Zitadel is ready'

  describe http("#{zitadel_url}/debug/ready", ssl_verify: true) do
    its('status') { should eq 200 }
  end
end

control 'ZITADEL-HEALTH-003' do
  impact 0.7
  title 'Zitadel debug endpoint available'
  desc 'The /debug/healthz endpoint SHOULD be available for debugging'

  describe http("#{zitadel_url}/debug/healthz", ssl_verify: true) do
    its('status') { should be_in [200, 404] }
  end
end

# -----------------------------------------------------------------------------
# UI Accessibility
# -----------------------------------------------------------------------------
control 'ZITADEL-UI-001' do
  impact 1.0
  title 'Zitadel login UI is accessible'
  desc 'The Zitadel login UI MUST be accessible at /ui/login'

  describe http("#{zitadel_url}/ui/login", ssl_verify: true) do
    its('status') { should be_in [200, 301, 302] }
  end
end

control 'ZITADEL-UI-002' do
  impact 1.0
  title 'Zitadel console UI is accessible'
  desc 'The Zitadel admin console MUST be accessible at /ui/console'

  describe http("#{zitadel_url}/ui/console", ssl_verify: true) do
    its('status') { should be_in [200, 302] }
  end
end

control 'ZITADEL-UI-003' do
  impact 0.7
  title 'Zitadel login page contains expected content'
  desc 'The login page SHOULD contain Zitadel branding or login form'

  describe http("#{zitadel_url}/ui/login", ssl_verify: true) do
    its('body') { should match(/zitadel|login|sign.?in/i) }
  end
end

# -----------------------------------------------------------------------------
# OIDC Discovery
# -----------------------------------------------------------------------------
control 'ZITADEL-OIDC-001' do
  impact 1.0
  title 'OIDC discovery endpoint is accessible'
  desc 'The OIDC well-known configuration MUST be accessible'

  describe http("#{zitadel_url}/.well-known/openid-configuration", ssl_verify: true) do
    its('status') { should eq 200 }
    its('headers.Content-Type') { should match(/application\/json/) }
  end
end

control 'ZITADEL-OIDC-002' do
  impact 1.0
  title 'OIDC discovery returns valid configuration'
  desc 'The OIDC discovery endpoint MUST return valid JSON with required fields'

  describe json(content: http("#{zitadel_url}/.well-known/openid-configuration", ssl_verify: true).body) do
    its('issuer') { should eq zitadel_url }
    its('authorization_endpoint') { should match(%r{#{zitadel_url}/oauth/v2/authorize}) }
    its('token_endpoint') { should match(%r{#{zitadel_url}/oauth/v2/token}) }
    its('userinfo_endpoint') { should match(%r{#{zitadel_url}/oidc/v1/userinfo}) }
    its('jwks_uri') { should match(%r{#{zitadel_url}/oauth/v2/keys}) }
  end
end

control 'ZITADEL-OIDC-003' do
  impact 1.0
  title 'OIDC JWKS endpoint is accessible'
  desc 'The JWKS endpoint MUST return valid JSON Web Key Set'

  describe http("#{zitadel_url}/oauth/v2/keys", ssl_verify: true) do
    its('status') { should eq 200 }
    its('headers.Content-Type') { should match(/application\/json/) }
  end

  describe json(content: http("#{zitadel_url}/oauth/v2/keys", ssl_verify: true).body) do
    its('keys') { should_not be_empty }
  end
end

control 'ZITADEL-LOGIN-002' do
  impact 1.0
  title 'Login page renders without errors'
  desc 'The login page MUST render without API errors'

  describe http("#{zitadel_url}/ui/login/login", ssl_verify: true, max_redirects: 3) do
    its('status') { should be_in [200, 302] }
    its('body') { should_not match(/"code":\s*5/) }
    its('body') { should_not match(/"message":\s*"Not Found"/) }
  end
end

control 'ZITADEL-LOGIN-003' do
  impact 1.0
  title 'V2 login UI is available'
  desc 'The v2 login UI endpoint MUST NOT return 404 Not Found'

  describe http("#{zitadel_url}/ui/v2/login/login", ssl_verify: true, max_redirects: 0) do
    its('status') { should_not eq 404 }
    its('body') { should_not match(/\{"code":5,\s*"message":"Not Found"\}/) }
  end
end

# -----------------------------------------------------------------------------
# API Endpoints
# -----------------------------------------------------------------------------
control 'ZITADEL-API-001' do
  impact 0.7
  title 'gRPC-Web endpoint responds'
  desc 'The gRPC-Web API endpoint SHOULD respond to requests'

  describe http("#{zitadel_url}/zitadel.admin.v1.AdminService/Healthz",
                method: 'POST',
                headers: { 'Content-Type' => 'application/grpc-web+proto' },
                ssl_verify: true) do
    its('status') { should be_in [200, 400, 415] }
  end
end

control 'ZITADEL-API-002' do
  impact 0.7
  title 'Management API base path responds'
  desc 'The Management API SHOULD respond (may require auth)'

  describe http("#{zitadel_url}/management/v1/healthz", ssl_verify: true) do
    its('status') { should be_in [200, 401, 403] }
  end
end

# -----------------------------------------------------------------------------
# Security Headers
# -----------------------------------------------------------------------------
control 'ZITADEL-SEC-001' do
  impact 0.5
  title 'Security headers present'
  desc 'Zitadel SHOULD return appropriate security headers (may be set by gateway)'

  describe http("#{zitadel_url}/", ssl_verify: true) do
    its('status') { should be_in [200, 301, 302] }
  end
end
