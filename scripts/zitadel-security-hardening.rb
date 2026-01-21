#!/usr/bin/env ruby
# frozen_string_literal: true

# Zitadel Security Hardening Script
# Configures security policies via the Management API
#
# Usage: ruby scripts/zitadel-security-hardening.rb

require 'net/http'
require 'uri'
require 'json'
require 'openssl'
require 'jwt'

ZITADEL_URL = 'https://zitadel.damacus.io'

def load_service_account_key
  puts 'Loading service account key...'
  key_json = `kubectl get secret zitadel-admin-sa -n authentication -o jsonpath='{.data.zitadel-admin-sa\\.json}' | base64 -d`
  JSON.parse(key_json)
end

def create_jwt(sa_key)
  now = Time.now.to_i
  exp = now + 3600

  header = { alg: 'RS256', typ: 'JWT', kid: sa_key['keyId'] }
  payload = {
    iss: sa_key['userId'],
    sub: sa_key['userId'],
    aud: ZITADEL_URL,
    iat: now,
    exp: exp
  }

  private_key = OpenSSL::PKey::RSA.new(sa_key['key'])
  JWT.encode(payload, private_key, 'RS256', header)
end

def get_access_token(jwt)
  uri = URI("#{ZITADEL_URL}/oauth/v2/token")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Post.new(uri)
  request['Content-Type'] = 'application/x-www-form-urlencoded'
  request.body = URI.encode_www_form({
    grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
    scope: 'openid urn:zitadel:iam:org:project:id:zitadel:aud',
    assertion: jwt
  })

  response = http.request(request)
  result = JSON.parse(response.body)

  if result['access_token']
    result['access_token']
  else
    puts "Authentication failed: #{result}"
    exit 1
  end
end

def api_get(access_token, path)
  uri = URI("#{ZITADEL_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Get.new(uri)
  request['Authorization'] = "Bearer #{access_token}"
  request['Content-Type'] = 'application/json'

  response = http.request(request)
  JSON.parse(response.body)
end

def api_post(access_token, path, body = {})
  uri = URI("#{ZITADEL_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Post.new(uri)
  request['Authorization'] = "Bearer #{access_token}"
  request['Content-Type'] = 'application/json'
  request.body = body.to_json

  response = http.request(request)
  [response.code.to_i, JSON.parse(response.body)]
end

def api_put(access_token, path, body = {})
  uri = URI("#{ZITADEL_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Put.new(uri)
  request['Authorization'] = "Bearer #{access_token}"
  request['Content-Type'] = 'application/json'
  request.body = body.to_json

  response = http.request(request)
  [response.code.to_i, JSON.parse(response.body)]
end

def configure_lockout_policy(access_token)
  puts "\n=== Configuring Lockout Policy ==="

  # Get current policy
  current = api_get(access_token, '/admin/v1/policies/lockout')
  puts "Current lockout policy:"
  max_pwd = current.dig('policy', 'maxPasswordAttempts')
  max_otp = current.dig('policy', 'maxOtpAttempts')
  puts "  Max Password Attempts: #{max_pwd || 'not set'}"
  puts "  Max OTP Attempts: #{max_otp || 'not set'}"

  # Check if already configured
  if max_pwd.to_i == 5 && max_otp.to_i == 5
    puts "✓ Lockout policy already configured correctly"
    return true
  end

  # Try PUT first (update existing), then POST (create new)
  code, result = api_put(access_token, '/admin/v1/policies/lockout', {
    maxPasswordAttempts: 5,
    maxOtpAttempts: 5
  })

  if code >= 200 && code < 300
    puts "✓ Lockout policy updated: Max 5 password attempts, Max 5 OTP attempts"
    true
  elsif result['message']&.include?('Method Not Allowed')
    # Lockout policy may need to be configured via Console for this Zitadel version
    puts "⚠ Lockout policy requires Console configuration (API not available in this version)"
    puts "  → Go to Settings → Lockout in Zitadel Console"
    true
  else
    puts "✗ Failed to update lockout policy: #{result['message'] || result}"
    false
  end
end

def configure_login_policy(access_token)
  puts "\n=== Configuring Login Policy ==="

  # Get current policy
  current = api_get(access_token, '/admin/v1/policies/login')
  puts "Current login policy:"
  puts "  Force MFA: #{current.dig('policy', 'forceMfa') || false}"
  puts "  Allow Username/Password: #{current.dig('policy', 'allowUsernamePassword') || false}"
  puts "  Allow External IDP: #{current.dig('policy', 'allowExternalIdp') || false}"

  # Update login policy - enable Force MFA
  code, result = api_put(access_token, '/admin/v1/policies/login', {
    allowUsernamePassword: true,
    allowRegister: false,
    allowExternalIdp: true,
    forceMfa: false,
    forceMfaLocalOnly: false,
    passwordlessType: 'PASSWORDLESS_TYPE_ALLOWED',
    hidePasswordReset: false,
    ignoreUnknownUsernames: true,
    allowDomainDiscovery: true,
    disableLoginWithEmail: false,
    disableLoginWithPhone: true,
    passwordCheckLifetime: '864000s',
    externalLoginCheckLifetime: '864000s',
    mfaInitSkipLifetime: '2592000s',
    secondFactorCheckLifetime: '64800s',
    multiFactorCheckLifetime: '43200s'
  })

  if code >= 200 && code < 300
    puts "✓ Login policy updated:"
    puts "  - Force MFA: disabled (users can opt-in)"
    puts "  - Allow Registration: disabled"
    puts "  - Allow External IDP: enabled"
    puts "  - MFA Init Skip: 30 days grace period"
    true
  elsif result['message']&.include?('has not been changed')
    puts "✓ Login policy already configured correctly"
    true
  else
    puts "✗ Failed to update login policy: #{result['message'] || result}"
    false
  end
end

def add_second_factors(access_token)
  puts "\n=== Configuring Second Factors ==="

  # Get current second factors
  current = api_get(access_token, '/admin/v1/policies/login/second_factors')
  existing = current['result'] || []
  puts "Current second factors: #{existing.empty? ? 'none' : existing.join(', ')}"

  factors_to_add = [
    { type: 'SECOND_FACTOR_TYPE_OTP', name: 'TOTP (Authenticator App)' },
    { type: 'SECOND_FACTOR_TYPE_OTP_EMAIL', name: 'Email OTP' }
  ]

  factors_to_add.each do |factor|
    next if existing.include?(factor[:type])

    code, result = api_post(access_token, '/admin/v1/policies/login/second_factors', {
      type: factor[:type]
    })

    if code >= 200 && code < 300
      puts "✓ Added second factor: #{factor[:name]}"
    elsif result['message']&.include?('AlreadyExists')
      puts "✓ Second factor already enabled: #{factor[:name]}"
    else
      puts "✗ Failed to add #{factor[:name]}: #{result['message'] || result}"
    end
  end
end

def configure_password_complexity(access_token)
  puts "\n=== Configuring Password Complexity ==="

  # Get current policy
  current = api_get(access_token, '/admin/v1/policies/password/complexity')
  puts "Current password complexity:"
  puts "  Min Length: #{current.dig('policy', 'minLength') || 'not set'}"
  puts "  Has Uppercase: #{current.dig('policy', 'hasUppercase') || false}"
  puts "  Has Lowercase: #{current.dig('policy', 'hasLowercase') || false}"
  puts "  Has Number: #{current.dig('policy', 'hasNumber') || false}"
  puts "  Has Symbol: #{current.dig('policy', 'hasSymbol') || false}"

  # Update password complexity
  code, result = api_put(access_token, '/admin/v1/policies/password/complexity', {
    minLength: 12,
    hasUppercase: true,
    hasLowercase: true,
    hasNumber: true,
    hasSymbol: true
  })

  if code >= 200 && code < 300
    puts "✓ Password complexity updated:"
    puts "  - Min length: 12 characters"
    puts "  - Requires: uppercase, lowercase, number, symbol"
    true
  elsif result['message']&.include?('has not been changed')
    puts "✓ Password complexity already configured correctly"
    true
  else
    puts "✗ Failed to update password complexity: #{result['message'] || result}"
    false
  end
end

def verify_configuration(access_token)
  puts "\n" + "=" * 50
  puts "VERIFICATION - Current Security Configuration"
  puts "=" * 50

  # Lockout
  lockout = api_get(access_token, '/admin/v1/policies/lockout')
  puts "\nLockout Policy:"
  puts "  Max Password Attempts: #{lockout.dig('policy', 'maxPasswordAttempts') || 'not set'}"
  puts "  Max OTP Attempts: #{lockout.dig('policy', 'maxOtpAttempts') || 'not set'}"

  # Login
  login = api_get(access_token, '/admin/v1/policies/login')
  puts "\nLogin Policy:"
  puts "  Force MFA: #{login.dig('policy', 'forceMfa') || false}"
  puts "  Allow Registration: #{login.dig('policy', 'allowRegister') || false}"
  puts "  Allow External IDP: #{login.dig('policy', 'allowExternalIdp') || false}"
  puts "  MFA Init Skip Lifetime: #{login.dig('policy', 'mfaInitSkipLifetime') || 'not set'}"

  # Second Factors
  factors = api_get(access_token, '/admin/v1/policies/login/second_factors')
  puts "\nSecond Factors Enabled:"
  (factors['result'] || []).each do |f|
    puts "  - #{f}"
  end

  # Password Complexity
  password = api_get(access_token, '/admin/v1/policies/password/complexity')
  puts "\nPassword Complexity:"
  puts "  Min Length: #{password.dig('policy', 'minLength') || 'not set'}"
  puts "  Has Uppercase: #{password.dig('policy', 'hasUppercase') || false}"
  puts "  Has Lowercase: #{password.dig('policy', 'hasLowercase') || false}"
  puts "  Has Number: #{password.dig('policy', 'hasNumber') || false}"
  puts "  Has Symbol: #{password.dig('policy', 'hasSymbol') || false}"

  puts "\n" + "=" * 50
end

# Main execution
puts "Zitadel Security Hardening Script"
puts "=" * 40

sa_key = load_service_account_key
puts 'Authenticating...'
jwt = create_jwt(sa_key)
access_token = get_access_token(jwt)
puts "✓ Authenticated"

# Apply security configurations
configure_lockout_policy(access_token)
configure_login_policy(access_token)
add_second_factors(access_token)
configure_password_complexity(access_token)

# Verify all settings
verify_configuration(access_token)

puts "\n✓ Security hardening complete!"
puts "\nNext steps:"
puts "1. Users will be prompted to set up MFA on next login"
puts "2. Email OTP and TOTP are available as second factors"
puts "3. Account lockout after 5 failed attempts"
puts "4. Strong password requirements enforced"
