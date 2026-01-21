#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'openssl'
require 'base64'
require 'time'

ZITADEL_URL = 'https://zitadel.ironstone.casa'
SA_KEY_FILE = '/tmp/zitadel-sa.json'

# Load service account key from Kubernetes secret
def load_service_account_key
  cmd = 'kubectl get secret zitadel-admin-sa -n authentication -o jsonpath=\'{.data.zitadel-admin-sa\.json}\' | base64 -d'
  key_json = `#{cmd}`
  raise 'Failed to load service account key' unless $?.success?

  JSON.parse(key_json)
end

# Create JWT for authentication
def create_jwt(sa_key)
  header = { alg: 'RS256', typ: 'JWT', kid: sa_key['keyId'] }
  now = Time.now.to_i
  exp = now + 3600

  payload = {
    iss: sa_key['userId'],
    sub: sa_key['userId'],
    aud: ZITADEL_URL,
    iat: now,
    exp: exp
  }

  header_b64 = Base64.urlsafe_encode64(header.to_json, padding: false)
  payload_b64 = Base64.urlsafe_encode64(payload.to_json, padding: false)
  signing_input = "#{header_b64}.#{payload_b64}"

  key = OpenSSL::PKey::RSA.new(sa_key['key'])
  signature = key.sign(OpenSSL::Digest.new('SHA256'), signing_input)
  signature_b64 = Base64.urlsafe_encode64(signature, padding: false)

  "#{signing_input}.#{signature_b64}"
end

# Get access token
def get_access_token(sa_key)
  jwt = create_jwt(sa_key)

  uri = URI("#{ZITADEL_URL}/oauth/v2/token")
  params = {
    grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
    scope: 'openid urn:zitadel:iam:org:project:id:zitadel:aud',
    assertion: jwt
  }

  response = Net::HTTP.post_form(uri, params)
  raise "Authentication failed: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)['access_token']
end

# Create a human user
def create_user(token, email, first_name, last_name)
  uri = URI("#{ZITADEL_URL}/v2/users/human")

  body = {
    username: email.split('@').first,
    profile: {
      givenName: first_name,
      familyName: last_name
    },
    email: {
      email: email,
      isVerified: true
    }
  }

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Post.new(uri)
  request['Authorization'] = "Bearer #{token}"
  request['Content-Type'] = 'application/json'
  request.body = body.to_json

  response = http.request(request)

  if response.is_a?(Net::HTTPSuccess)
    result = JSON.parse(response.body)
    puts "✓ Created user: #{email} (ID: #{result['userId']})"
    result
  else
    puts "✗ Failed to create #{email}: #{response.body}"
    nil
  end
end

# Main execution
def main
  users = [
    { email: 'dan.m.webb@gmail.com', first_name: 'Dan', last_name: 'Webb', admin: true },
    { email: '28lauracummings@gmail.com', first_name: 'Laura', last_name: 'Cummings', admin: false },
    { email: 'webbglor@googlemail.com', first_name: 'Gloria', last_name: 'Webb', admin: false },
    { email: 'gtxthor37@gmail.com', first_name: 'Gordon', last_name: 'Webb', admin: false },
    { email: 'dan.webb@damacus.io', first_name: 'Daniel', last_name: 'Webb', admin: true }
  ]

  puts 'Loading service account key...'
  sa_key = load_service_account_key

  puts 'Authenticating...'
  token = get_access_token(sa_key)

  puts "\nCreating users..."
  users.each do |user|
    create_user(token, user[:email], user[:first_name], user[:last_name])
  end

  puts "\n✓ User creation complete"
  puts "\nNext steps:"
  puts "1. Users can now log in via Google OAuth"
  puts "2. Configure Zitadel Actions to assign groups (home-ops-6nw)"
  puts "3. Link Google accounts on first login"
end

main if __FILE__ == $PROGRAM_NAME
