require "minitest/autorun"

require_relative "../kubernetes/apps/authentication/zitadel/app/reconcile-access-policy"

class RecordingZitadelClient
  attr_reader :calls

  def initialize(
    policy,
    provider_converges: true,
    live_provider_ids: nil,
    login_update_delay: 0
  )
    @calls = []
    @provider = policy.fetch("identityProviders").fetch(0)
    @live_provider_ids = live_provider_ids || [@provider.fetch("id")]
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
    @login_update_delay = login_update_delay
    @pending_login = nil
  end

  def post(path, _body)
    @calls << [:post, path]
    { "result" => @live_provider_ids.map { |id| { "idpId" => id } } }
  end

  def get(path)
    @calls << [:get, path]
    if path == "/admin/v1/policies/login"
      if @pending_login
        if @login_update_delay.positive?
          @login_update_delay -= 1
        else
          @current_login = @pending_login
          @pending_login = nil
        end
      end
      return { "policy" => @current_login }
    end
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
      if @login_update_delay.zero?
        @current_login = body
      else
        @pending_login = body
      end
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

  def test_rejects_an_unexpected_live_provider_without_writing
    policy = load_policy(POLICY_PATH)
    desired_id = policy.fetch("identityProviders").fetch(0).fetch("id")
    client = RecordingZitadelClient.new(
      policy,
      live_provider_ids: [desired_id, "unexpected-provider"]
    )

    assert_raises(PolicyError) do
      capture_io do
        reconcile_policy(policy, client: client, sleeper: ->(_seconds) {})
      end
    end

    writes = client.calls.select { |operation, _path| operation == :put }
    assert_empty writes
  end

  def test_retries_final_login_policy_verification_until_it_converges
    policy = load_policy(POLICY_PATH)
    client = RecordingZitadelClient.new(policy, login_update_delay: 1)

    capture_io do
      reconcile_policy(policy, client: client, sleeper: ->(_seconds) {})
    end

    login_path = "/admin/v1/policies/login"
    login_put = client.calls.index do |operation, path|
      operation == :put && path == login_path
    end
    verification_reads = client.calls[(login_put + 1)..].count do |operation, path|
      operation == :get && path == login_path
    end

    assert_operator verification_reads, :>=, 2
  end
end
