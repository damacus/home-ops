require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"
require "yaml"

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

def option_value(options, key)
  return options[key] if options.key?(key)

  false
end

def verify_policy(client, policy)
  login_policy = client.get("/admin/v1/policies/login").fetch("policy")
  expected_register = policy.fetch("loginPolicy").fetch("allowRegister")
  actual_register = option_value(login_policy, "allowRegister")
  raise "allowRegister drifted: expected #{expected_register}" unless actual_register == expected_register

  policy.fetch("identityProviders").each do |provider|
    id = provider.fetch("id")
    options = client.get("/admin/v1/idps/templates/#{id}")
      .dig("idp", "config", "options")
      .then { |value| value || {} }

    provider.fetch("providerOptions").each do |key, expected|
      actual = option_value(options, key)
      raise "#{provider.fetch("type")} #{key} drifted: expected #{expected}" unless actual == expected
    end
  end
end

policy = YAML.safe_load(
  File.read(ENV.fetch("ZITADEL_POLICY_FILE")),
  aliases: false
)
client = ZitadelClient.new(
  endpoint: ENV.fetch("ZITADEL_ENDPOINT"),
  issuer: ENV.fetch("ZITADEL_ISSUER"),
  key_file: ENV.fetch("ZITADEL_SERVICE_ACCOUNT_KEY")
)

desired_login = policy.fetch("loginPolicy")
current_login = client.get("/admin/v1/policies/login").fetch("policy")
login_drifted = desired_login.any? do |key, expected|
  option_value(current_login, key) != expected
end
client.put("/admin/v1/policies/login", desired_login) if login_drifted

policy.fetch("identityProviders").each do |provider|
  type = provider.fetch("type")
  raise "unsupported identity provider type: #{type}" unless type == "google"

  current = client.get("/admin/v1/idps/templates/#{provider.fetch("id")}").fetch("idp")
  desired_options = provider.fetch("providerOptions")
  current_options = current.fetch("config").fetch("options")
  options_drifted = desired_options.any? do |key, expected|
    option_value(current_options, key) != expected
  end
  next unless options_drifted

  google_config = current.fetch("config").fetch("google")
  client.put(
    "/admin/v1/idps/#{type}/#{provider.fetch("id")}",
    {
      "name" => current.fetch("name"),
      "clientId" => google_config.fetch("clientId"),
      "scopes" => google_config.fetch("scopes"),
      "providerOptions" => desired_options
    }
  )
end

verify_policy(client, policy)
puts "Zitadel account admission policy reconciled and verified"
