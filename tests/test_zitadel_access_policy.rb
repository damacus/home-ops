require "minitest/autorun"

require_relative "../kubernetes/apps/authentication/zitadel/app/reconcile-access-policy"

class RecordingZitadelClient
  attr_reader :calls

  def initialize(policy, provider_converges: true)
    @calls = []
    @provider = policy.fetch("identityProviders").fetch(0)
    @desired_options = @provider.fetch("providerOptions")
    @current_options = @desired_options.merge(
      "isCreationAllowed" => true,
      "isAutoCreation" => true
    )
    @desired_login = policy.fetch("loginPolicy")
    @current_login = @desired_login.merge("allowExternalIdp" => false)
    @provider_converges = provider_converges
    @provider_updated = false
    @provider_update_pending = false
  end

  def post(path, _body)
    @calls << [:post, path]
    { "result" => [{ "idpId" => @provider.fetch("id") }] }
  end

  def get(path)
    @calls << [:get, path]
    return { "policy" => @current_login } if path == "/admin/v1/policies/login"
    return provider_response(@current_options) unless @provider_updated

    if @provider_update_pending
      @provider_update_pending = false
      return provider_response(@current_options)
    end

    @current_options = @desired_options if @provider_converges
    provider_response(@current_options)
  end

  def put(path, body)
    @calls << [:put, path]
    if path == "/admin/v1/policies/login"
      @current_login = body
    else
      @provider_updated = true
      @provider_update_pending = true
    end
    { "details" => { "sequence" => 2 } }
  end

  private

  def provider_response(options)
    {
      "idp" => {
        "name" => "Google",
        "config" => {
          "options" => options,
          "google" => {
            "clientId" => "client-id",
            "scopes" => %w[openid profile email]
          }
        }
      }
    }
  end
end

class ZitadelAccessPolicyTest < Minitest::Test
  POLICY_PATH = File.expand_path(
    "../kubernetes/apps/authentication/zitadel/app/access-policy.yaml",
    __dir__
  )

  def test_verifies_provider_before_enabling_external_login
    policy = load_policy(POLICY_PATH)
    client = RecordingZitadelClient.new(policy)

    capture_io do
      reconcile_policy(policy, client: client, sleeper: ->(_seconds) {})
    end

    provider_id = policy.fetch("identityProviders").fetch(0).fetch("id")
    provider_path = "/admin/v1/idps/templates/#{provider_id}"
    provider_put = client.calls.index do |operation, path|
      operation == :put && path.include?("/idps/google/")
    end
    login_put = client.calls.index do |operation, path|
      operation == :put && path == "/admin/v1/policies/login"
    end
    verification_reads = client.calls[provider_put...login_put].count do |operation, path|
      operation == :get && path == provider_path
    end

    assert_operator verification_reads, :>=, 2
    assert_operator provider_put, :<, login_put
  end

  def test_does_not_enable_external_login_when_provider_remains_unsafe
    policy = load_policy(POLICY_PATH)
    client = RecordingZitadelClient.new(policy, provider_converges: false)

    assert_raises(RuntimeError) do
      capture_io do
        reconcile_policy(policy, client: client, sleeper: ->(_seconds) {})
      end
    end

    login_updated = client.calls.any? do |operation, path|
      operation == :put && path == "/admin/v1/policies/login"
    end
    refute login_updated
  end
end
