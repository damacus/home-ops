require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"
require "yaml"

class PolicyError < StandardError; end

LOGIN_POLICY_KEYS = %w[
  allowUsernamePassword
  allowRegister
  allowExternalIdp
  forceMfa
  passwordlessType
  hidePasswordReset
  ignoreUnknownUsernames
  defaultRedirectUri
  passwordCheckLifetime
  externalLoginCheckLifetime
  mfaInitSkipLifetime
  secondFactorCheckLifetime
  multiFactorCheckLifetime
  allowDomainDiscovery
  disableLoginWithEmail
  disableLoginWithPhone
  forceMfaLocalOnly
].freeze

LOGIN_POLICY_REQUIRED_VALUES = {
  "allowUsernamePassword" => true,
  "allowRegister" => false,
  "allowExternalIdp" => true,
  "forceMfa" => false,
  "passwordlessType" => "PASSWORDLESS_TYPE_ALLOWED",
  "hidePasswordReset" => false,
  "ignoreUnknownUsernames" => true,
  "defaultRedirectUri" => "",
  "allowDomainDiscovery" => false,
  "disableLoginWithEmail" => false,
  "disableLoginWithPhone" => true,
  "forceMfaLocalOnly" => false
}.freeze

LOGIN_POLICY_DURATION_KEYS = %w[
  passwordCheckLifetime
  externalLoginCheckLifetime
  mfaInitSkipLifetime
  secondFactorCheckLifetime
  multiFactorCheckLifetime
].freeze

PROVIDER_KEYS = %w[id type providerOptions].freeze
GOOGLE_PROVIDER_OPTION_VALUES = {
  "isLinkingAllowed" => true,
  "isCreationAllowed" => false,
  "isAutoCreation" => false,
  "isAutoUpdate" => true,
  "autoLinking" => "AUTO_LINKING_OPTION_EMAIL"
}.freeze

class ZitadelClient
  API_SCOPE = "openid urn:zitadel:iam:org:project:id:zitadel:aud"
  JWT_GRANT = "urn:ietf:params:oauth:grant-type:jwt-bearer"

  def initialize(endpoint:, issuer:, key_file:)
    @endpoint = URI(endpoint)
    @issuer = URI(issuer)
    @key = JSON.parse(File.read(key_file))
    @access_token = fetch_access_token
  end

  def get(path)
    request(Net::HTTP::Get, path)
  end

  def put(path, body)
    request(Net::HTTP::Put, path, body)
  end

  def post(path, body)
    request(Net::HTTP::Post, path, body)
  end

  private

  def base64url(value)
    Base64.urlsafe_encode64(value, padding: false)
  end

  def fetch_access_token
    now = Time.now.to_i
    header = base64url(JSON.generate({ alg: "RS256", kid: @key.fetch("keyId") }))
    payload = base64url(JSON.generate({
      iss: @key.fetch("userId"),
      sub: @key.fetch("userId"),
      aud: @issuer.to_s,
      iat: now,
      exp: now + 300
    }))
    signature = OpenSSL::PKey::RSA.new(@key.fetch("key")).sign(
      OpenSSL::Digest::SHA256.new,
      "#{header}.#{payload}"
    )

    uri = endpoint_uri("/oauth/v2/token")
    request = Net::HTTP::Post.new(uri)
    add_routing_headers(request)
    request.set_form_data({
      "grant_type" => JWT_GRANT,
      "scope" => API_SCOPE,
      "assertion" => "#{header}.#{payload}.#{base64url(signature)}"
    })

    response = perform(uri, request)
    ensure_success!(response, "token request")
    JSON.parse(response.body).fetch("access_token")
  end

  def request(request_class, path, body = nil)
    uri = endpoint_uri(path)
    request = request_class.new(uri)
    add_routing_headers(request)
    request["Authorization"] = "Bearer #{@access_token}"
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end

    response = perform(uri, request)
    ensure_success!(response, "#{request.method} #{path}")
    response.body.empty? ? {} : JSON.parse(response.body)
  end

  def endpoint_uri(path)
    URI("#{@endpoint.to_s.delete_suffix("/")}#{path}")
  end

  def add_routing_headers(request)
    request["Host"] = @issuer.host
    request["X-Forwarded-Proto"] = @issuer.scheme
    request["X-Zitadel-Instance-Host"] = @issuer.host
  end

  def perform(uri, request)
    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: 10,
      read_timeout: 20
    ) { |http| http.request(request) }
  end

  def ensure_success!(response, operation)
    return if response.is_a?(Net::HTTPSuccess)

    raise "#{operation} failed: HTTP #{response.code}: #{response.body[0, 500]}"
  end
end

def validate_exact_keys!(value, expected_keys, context)
  raise PolicyError, "#{context} must be an object" unless value.is_a?(Hash)

  actual_keys = value.keys.map(&:to_s)
  missing = expected_keys - actual_keys
  unexpected = actual_keys - expected_keys
  return if missing.empty? && unexpected.empty?

  problems = []
  problems << "missing: #{missing.join(", ")}" unless missing.empty?
  problems << "unexpected: #{unexpected.join(", ")}" unless unexpected.empty?
  raise PolicyError, "#{context} is incomplete (#{problems.join("; ")})"
end

def validate_required_values!(value, required_values, context)
  required_values.each do |key, expected|
    actual = value.fetch(key)
    next if actual == expected

    raise PolicyError,
      "#{context}.#{key} must be #{expected.inspect}, got #{actual.inspect}"
  end
end

def validate_policy!(policy)
  validate_exact_keys!(policy, %w[loginPolicy identityProviders], "policy")

  login_policy = policy.fetch("loginPolicy")
  validate_exact_keys!(login_policy, LOGIN_POLICY_KEYS, "loginPolicy")
  validate_required_values!(
    login_policy,
    LOGIN_POLICY_REQUIRED_VALUES,
    "loginPolicy"
  )
  LOGIN_POLICY_DURATION_KEYS.each do |key|
    value = login_policy.fetch(key)
    next if value.is_a?(String) && value.match?(/\A[1-9]\d*s\z/)

    raise PolicyError, "loginPolicy.#{key} must be a positive duration in seconds"
  end

  providers = policy.fetch("identityProviders")
  unless providers.is_a?(Array) && !providers.empty?
    raise PolicyError, "identityProviders must be a non-empty list"
  end

  provider_ids = providers.map.with_index do |provider, index|
    context = "identityProviders[#{index}]"
    validate_exact_keys!(provider, PROVIDER_KEYS, context)

    provider_id = provider.fetch("id")
    unless provider_id.is_a?(String) && !provider_id.empty?
      raise PolicyError, "#{context}.id must be a non-empty string"
    end

    provider_type = provider.fetch("type")
    unless provider_type == "google"
      raise PolicyError, "#{context}.type is unsupported: #{provider_type.inspect}"
    end

    options = provider.fetch("providerOptions")
    validate_exact_keys!(
      options,
      GOOGLE_PROVIDER_OPTION_VALUES.keys,
      "#{context}.providerOptions"
    )
    validate_required_values!(
      options,
      GOOGLE_PROVIDER_OPTION_VALUES,
      "#{context}.providerOptions"
    )
    provider_id
  end

  duplicates = provider_ids.tally.select { |_id, count| count > 1 }.keys
  unless duplicates.empty?
    raise PolicyError, "identityProviders contains duplicate IDs: #{duplicates.join(", ")}"
  end

  true
end

def load_policy(path)
  policy = YAML.safe_load(File.read(path), aliases: false)
  validate_policy!(policy)
  policy
end

def option_value(options, key, expected)
  return options[key] if options.key?(key)

  return false if expected == true || expected == false
  return "" if expected.is_a?(String)

  nil
end

def drifted?(current, desired)
  desired.any? do |key, expected|
    option_value(current, key, expected) != expected
  end
end

def assert_identity_provider_allowlist!(client, providers)
  response = client.post("/admin/v1/policies/login/idps/_search", {})
  live_ids = response.fetch("result", []).map do |provider|
    provider.fetch("idpId").to_s
  end
  desired_ids = providers.map { |provider| provider.fetch("id") }
  return if live_ids.sort == desired_ids.sort

  missing = desired_ids - live_ids
  unexpected = live_ids - desired_ids
  problems = []
  problems << "missing from login policy: #{missing.join(", ")}" unless missing.empty?
  problems << "not declared in Git: #{unexpected.join(", ")}" unless unexpected.empty?
  raise PolicyError, "identity provider allowlist mismatch (#{problems.join("; ")})"
end

def verify_policy(client, policy)
  login_policy = client.get("/admin/v1/policies/login").fetch("policy")
  policy.fetch("loginPolicy").each do |key, expected|
    actual = option_value(login_policy, key, expected)
    next if actual == expected

    raise "loginPolicy.#{key} drifted: expected #{expected.inspect}, got #{actual.inspect}"
  end

  policy.fetch("identityProviders").each do |provider|
    id = provider.fetch("id")
    options = client.get("/admin/v1/idps/templates/#{id}")
      .dig("idp", "config", "options")
      .then { |value| value || {} }

    provider.fetch("providerOptions").each do |key, expected|
      actual = option_value(options, key, expected)
      next if actual == expected

      raise "#{provider.fetch("type")} #{key} drifted: expected #{expected.inspect}, got #{actual.inspect}"
    end
  end
end

def reconcile_policy(policy)
  client = ZitadelClient.new(
    endpoint: ENV.fetch("ZITADEL_ENDPOINT"),
    issuer: ENV.fetch("ZITADEL_ISSUER"),
    key_file: ENV.fetch("ZITADEL_SERVICE_ACCOUNT_KEY")
  )
  providers = policy.fetch("identityProviders")
  assert_identity_provider_allowlist!(client, providers)

  provider_updates = providers.map do |provider|
    type = provider.fetch("type")
    id = provider.fetch("id")
    current = client.get("/admin/v1/idps/templates/#{id}").fetch("idp")
    desired_options = provider.fetch("providerOptions")
    current_options = current.fetch("config").fetch("options", {})
    next unless drifted?(current_options, desired_options)

    google_config = current.fetch("config").fetch("google")
    [
      "/admin/v1/idps/#{type}/#{id}",
      {
        "name" => current.fetch("name"),
        "clientId" => google_config.fetch("clientId"),
        "scopes" => google_config.fetch("scopes"),
        "providerOptions" => desired_options
      }
    ]
  end
  desired_login = policy.fetch("loginPolicy")
  current_login = client.get("/admin/v1/policies/login").fetch("policy")
  login_drifted = drifted?(current_login, desired_login)

  provider_updates.compact.each do |path, body|
    client.put(path, body)
  end
  client.put("/admin/v1/policies/login", desired_login) if login_drifted

  verify_policy(client, policy)
  puts "Zitadel account admission policy reconciled and verified"
end

def main(arguments)
  if arguments.first == "--validate-policy"
    unless arguments.length == 2
      raise PolicyError, "usage: reconcile-access-policy.rb --validate-policy PATH"
    end

    load_policy(arguments.fetch(1))
    puts "Zitadel account admission policy is complete and safe"
    return 0
  end

  unless arguments.empty?
    raise PolicyError, "unexpected arguments: #{arguments.join(" ")}"
  end

  policy = load_policy(ENV.fetch("ZITADEL_POLICY_FILE"))
  reconcile_policy(policy)
  0
rescue StandardError => e
  warn "Zitadel account admission policy failed: #{e.message}"
  1
end

exit(main(ARGV)) if __FILE__ == $PROGRAM_NAME
