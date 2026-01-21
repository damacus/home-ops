#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'openssl'
require 'jwt'

ZITADEL_URL = 'https://zitadel.damacus.io'
PROJECT_ID = '355223427969320100'

def load_service_account_key
  key_json = `kubectl get secret zitadel-admin-sa -n authentication -o jsonpath='{.data.zitadel-admin-sa\\.json}' | base64 -d`
  JSON.parse(key_json)
end

def create_jwt(sa_key)
  now = Time.now.to_i
  exp = now + 3600
  header = { alg: 'RS256', typ: 'JWT', kid: sa_key['keyId'] }
  payload = { iss: sa_key['userId'], sub: sa_key['userId'], aud: ZITADEL_URL, iat: now, exp: exp }
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
  result['access_token'] || (puts "Auth failed: #{result}"; exit 1)
end

def list_apps(access_token)
  uri = URI("#{ZITADEL_URL}/management/v1/projects/#{PROJECT_ID}/apps/_search")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = Net::HTTP::Post.new(uri)
  request['Authorization'] = "Bearer #{access_token}"
  request['Content-Type'] = 'application/json'
  request.body = '{}'
  response = http.request(request)
  JSON.parse(response.body)
end

# Main
sa_key = load_service_account_key
jwt = create_jwt(sa_key)
access_token = get_access_token(jwt)

puts "Listing OIDC apps in Zitadel...\n\n"
apps = list_apps(access_token)

apps['result']&.each do |app|
  next unless app['oidcConfig']

  name = app['name']
  app_id = app['id']
  redirect_uris = app['oidcConfig']['redirectUris'] || []

  puts "#{name} (#{app_id}):"
  redirect_uris.each { |uri| puts "  - #{uri}" }
  puts
end

puts "\nTotal OIDC apps: #{apps['result']&.count { |a| a['oidcConfig'] } || 0}"
