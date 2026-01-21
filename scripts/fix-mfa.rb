#!/usr/bin/env ruby
require 'net/http'
require 'uri'
require 'json'
require 'openssl'
require 'jwt'

ZITADEL_URL = 'https://zitadel.damacus.io'

key_json = `kubectl get secret zitadel-admin-sa -n authentication -o jsonpath='{.data.zitadel-admin-sa\\.json}' | base64 -d`
sa_key = JSON.parse(key_json)
now = Time.now.to_i
header = { alg: 'RS256', typ: 'JWT', kid: sa_key['keyId'] }
payload = { iss: sa_key['userId'], sub: sa_key['userId'], aud: ZITADEL_URL, iat: now, exp: now + 3600 }
private_key = OpenSSL::PKey::RSA.new(sa_key['key'])
jwt = JWT.encode(payload, private_key, 'RS256', header)

uri = URI("#{ZITADEL_URL}/oauth/v2/token")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true
request = Net::HTTP::Post.new(uri)
request['Content-Type'] = 'application/x-www-form-urlencoded'
request.body = URI.encode_www_form({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', scope: 'openid urn:zitadel:iam:org:project:id:zitadel:aud', assertion: jwt })
response = http.request(request)
access_token = JSON.parse(response.body)['access_token']

puts "Disabling Force MFA..."

uri = URI("#{ZITADEL_URL}/admin/v1/policies/login")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true
request = Net::HTTP::Put.new(uri)
request['Authorization'] = "Bearer #{access_token}"
request['Content-Type'] = 'application/json'
request.body = {
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
}.to_json
response = http.request(request)
puts "Status: #{response.code}"
result = JSON.parse(response.body)
if response.code.to_i >= 200 && response.code.to_i < 300
  puts "✓ Force MFA DISABLED - login should work now"
else
  puts "Result: #{result}"
end
