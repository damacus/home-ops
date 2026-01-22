# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'openssl'
require 'base64'
require 'time'

module ZitadelTui
  class Client
    attr_reader :config

    def initialize(config: Config.new)
      @config = config
      @sa_key = nil
      @token = nil
      @pat = nil
    end

    def authenticate
      @sa_key = load_service_account_key
      @token = get_access_token
      true
    rescue StandardError => e
      raise AuthenticationError, "Authentication failed: #{e.message}"
    end

    def authenticate_with_pat
      @pat = load_pat
      true
    rescue StandardError => e
      raise AuthenticationError, "PAT authentication failed: #{e.message}"
    end

    def authenticated?
      !@token.nil? || !@pat.nil?
    end

    # Project operations
    def list_projects
      result = api_request(:post, '/management/v1/projects/_search', { query: { limit: 100 } })
      result['result'] || []
    end

    def get_default_project
      projects = list_projects
      raise ApiError, 'No projects found' if projects.empty?

      projects.first
    end

    # App operations
    def list_apps(project_id)
      result = api_request(:post, "/management/v1/projects/#{project_id}/apps/_search", { query: { limit: 100 } })
      result['result'] || []
    end

    def create_oidc_app(project_id, name, redirect_uris, options = {})
      body = build_oidc_app_body(name, redirect_uris, options)
      api_request(:post, "/management/v1/projects/#{project_id}/apps/oidc", body)
    end

    def delete_app(project_id, app_id)
      api_request(:delete, "/management/v1/projects/#{project_id}/apps/#{app_id}")
    end

    def regenerate_secret(project_id, app_id)
      api_request(:put, "/management/v1/projects/#{project_id}/apps/#{app_id}/oidc_config/secret")
    end

    # User operations
    def list_users(limit: 100)
      result = api_request(:post, '/management/v1/users/_search', { query: { limit: limit } })
      result['result'] || []
    end

    def search_user(username)
      body = {
        query: { offset: '0', limit: 100, asc: true },
        queries: [{ userNameQuery: { userName: username, method: 'TEXT_QUERY_METHOD_EQUALS' } }]
      }
      result = api_request(:post, '/management/v1/users/_search', body)
      result['result']&.first
    end

    def create_human_user(email:, first_name:, last_name:, username: nil)
      body = {
        username: username || email.split('@').first,
        profile: { givenName: first_name, familyName: last_name },
        email: { email: email, isVerified: true }
      }
      api_request(:post, '/v2/users/human', body)
    end

    def import_human_user(username:, first_name:, last_name:, email:, password:, password_change_required: true)
      body = {
        userName: username,
        profile: { firstName: first_name, lastName: last_name, displayName: "#{first_name} #{last_name}" },
        email: { email: email, isEmailVerified: true },
        password: password,
        passwordChangeRequired: password_change_required
      }
      api_request(:post, '/management/v1/users/human/_import', body)
    end

    def grant_iam_owner(user_id)
      body = { userId: user_id, roles: ['IAM_OWNER'] }
      api_request(:post, '/admin/v1/members', body)
    end

    # IDP operations
    def add_google_idp(client_id:, client_secret:, name: 'Google')
      body = {
        name: name,
        clientId: client_id,
        clientSecret: client_secret,
        scopes: %w[openid profile email],
        providerOptions: {
          isLinkingAllowed: true,
          isCreationAllowed: true,
          isAutoCreation: false,
          isAutoUpdate: true
        }
      }
      api_request(:post, '/admin/v1/idps/google', body)
    end

    def list_idps
      result = api_request(:post, '/admin/v1/idps/_search', { query: { limit: 100 } })
      result['result'] || []
    end

    private

    def load_service_account_key
      key_file = config.sa_key_file

      unless File.exist?(key_file)
        encoded = kubectl_get_secret(
          Config::SA_SECRET_NAME,
          Config::SA_SECRET_NAMESPACE,
          Config::SA_SECRET_KEY
        )
        decoded = Base64.decode64(encoded)
        File.write(key_file, decoded)
      end

      JSON.parse(File.read(key_file))
    end

    def load_pat
      encoded = kubectl_get_secret(
        Config::PAT_SECRET_NAME,
        Config::SA_SECRET_NAMESPACE,
        Config::PAT_SECRET_KEY
      )
      Base64.decode64(encoded)
    end

    def kubectl_get_secret(name, namespace, key)
      escaped_key = key.gsub('.', '\\.')
      cmd = "kubectl get secret #{name} -n #{namespace} -o jsonpath='{.data.#{escaped_key}}'"
      result = `#{cmd}`.strip
      raise ApiError, "Failed to get secret #{name}" if result.empty?

      result
    end

    def base64url_encode(data)
      Base64.urlsafe_encode64(data, padding: false)
    end

    def create_jwt
      now = Time.now.to_i
      exp = now + 3600

      header = { alg: 'RS256', typ: 'JWT', kid: @sa_key['keyId'] }
      payload = {
        iss: @sa_key['userId'],
        sub: @sa_key['userId'],
        aud: config.zitadel_url,
        iat: now,
        exp: exp
      }

      header_b64 = base64url_encode(header.to_json)
      payload_b64 = base64url_encode(payload.to_json)
      signing_input = "#{header_b64}.#{payload_b64}"

      private_key = OpenSSL::PKey::RSA.new(@sa_key['key'])
      signature = private_key.sign(OpenSSL::Digest.new('SHA256'), signing_input)
      signature_b64 = base64url_encode(signature)

      "#{signing_input}.#{signature_b64}"
    end

    def get_access_token
      jwt = create_jwt

      uri = URI("#{config.zitadel_url}/oauth/v2/token")
      response = Net::HTTP.post_form(uri, {
                                       'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                                       'scope' => 'openid urn:zitadel:iam:org:project:id:zitadel:aud',
                                       'assertion' => jwt
                                     })

      raise AuthenticationError, "Token request failed: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)['access_token']
    end

    def api_request(method, path, body = nil)
      uri = URI("#{config.zitadel_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = build_request(method, uri)
      request['Authorization'] = "Bearer #{@token || @pat}"
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request.body = body.to_json if body

      response = http.request(request)
      handle_response(response)
    end

    def build_request(method, uri)
      case method
      when :get then Net::HTTP::Get.new(uri)
      when :post then Net::HTTP::Post.new(uri)
      when :put then Net::HTTP::Put.new(uri)
      when :delete then Net::HTTP::Delete.new(uri)
      else raise ArgumentError, "Unknown HTTP method: #{method}"
      end
    end

    def handle_response(response)
      unless response.is_a?(Net::HTTPSuccess)
        error_body = begin
          JSON.parse(response.body)
        rescue StandardError
          response.body
        end
        raise ApiError, "API request failed (#{response.code}): #{error_body}"
      end

      response.body.empty? ? {} : JSON.parse(response.body)
    end

    def build_oidc_app_body(name, redirect_uris, options)
      public_client = options[:public]
      app_type, auth_method = oidc_client_types(public_client)

      base_oidc_body(name, redirect_uris, app_type, auth_method).merge(
        grantTypes: options[:grant_types] || default_grant_types,
        postLogoutRedirectUris: options[:post_logout_uris] || [],
        devMode: options[:dev_mode] || false,
        accessTokenRoleAssertion: options.fetch(:role_assertion, true),
        idTokenRoleAssertion: options.fetch(:id_token_role_assertion, true),
        idTokenUserinfoAssertion: options.fetch(:id_token_userinfo_assertion, true),
        additionalOrigins: options[:additional_origins] || []
      )
    end

    def oidc_client_types(public_client)
      if public_client
        %w[OIDC_APP_TYPE_USER_AGENT OIDC_AUTH_METHOD_TYPE_NONE]
      else
        %w[OIDC_APP_TYPE_WEB OIDC_AUTH_METHOD_TYPE_BASIC]
      end
    end

    def base_oidc_body(name, redirect_uris, app_type, auth_method)
      {
        name: name,
        redirectUris: redirect_uris,
        responseTypes: ['OIDC_RESPONSE_TYPE_CODE'],
        appType: app_type,
        authMethodType: auth_method,
        version: 'OIDC_VERSION_1_0',
        accessTokenType: 'OIDC_TOKEN_TYPE_BEARER',
        clockSkew: '0s',
        skipNativeAppSuccessPage: false
      }
    end

    def default_grant_types
      %w[OIDC_GRANT_TYPE_AUTHORIZATION_CODE OIDC_GRANT_TYPE_REFRESH_TOKEN]
    end
  end
end
