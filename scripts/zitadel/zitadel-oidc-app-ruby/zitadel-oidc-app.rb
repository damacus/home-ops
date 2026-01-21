#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'openssl'
require 'base64'
require 'optparse'
require 'time'

ZITADEL_URL = 'https://zitadel.ironstone.casa'
SA_KEY_FILE = '/tmp/zitadel-sa.json'

module ZitadelOidcApp
  class Client
    def initialize
      @sa_key = load_service_account_key
      @token = nil
    end

    def authenticate
      puts 'Authenticating...'
      @token = get_access_token
    end

    def list_apps
      authenticate
      puts 'Getting project...'
      project_id = get_default_project
      puts "Project ID: #{project_id}\n\n"

      puts 'Applications:'
      puts '-' * 80

      apps = fetch_apps(project_id)
      apps.each do |app|
        client_id = app.dig('oidcConfig', 'clientId') || 'N/A'
        puts "  Name:      #{app['name']}"
        puts "  App ID:    #{app['id']}"
        puts "  Client ID: #{client_id}"
        puts "  State:     #{app['state']}"
        puts '-' * 80
      end
    end

    def delete_app(app_id)
      authenticate
      puts 'Getting project...'
      project_id = get_default_project

      puts "Deleting application #{app_id}..."
      api_request(:delete, "/management/v1/projects/#{project_id}/apps/#{app_id}")
      puts 'Application deleted successfully'
    end

    def create_app(name, redirect_uris)
      authenticate
      puts 'Getting project...'
      project_id = get_default_project

      puts "Creating OIDC application '#{name}'..."
      result = create_oidc_app(project_id, name, redirect_uris)

      puts
      puts '=' * 80
      puts 'OIDC APPLICATION CREATED SUCCESSFULLY'
      puts '=' * 80
      puts "\nApplication Name: #{name}"
      puts "Application ID:   #{result['appId']}"
      puts "Redirect URIs:    #{redirect_uris.join(', ')}"
      puts "\n--- CREDENTIALS (save to 1Password) ---"
      puts "client_id:     #{result['clientId']}"
      puts "client_secret: #{result['clientSecret']}"
      puts '=' * 80
      puts "\nAdd these to your 1Password item with fields:"
      puts '  - client_id'
      puts '  - client_secret'
    end

    private

    def load_service_account_key
      unless File.exist?(SA_KEY_FILE)
        puts 'Service account key not found. Extracting from Kubernetes...'
        encoded = `kubectl get secret zitadel-admin-sa -n authentication -o jsonpath='{.data.zitadel-admin-sa\\.json}'`
        decoded = Base64.decode64(encoded)
        File.write(SA_KEY_FILE, decoded)
      end

      JSON.parse(File.read(SA_KEY_FILE))
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
        aud: ZITADEL_URL,
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

      uri = URI("#{ZITADEL_URL}/oauth/v2/token")
      response = Net::HTTP.post_form(uri, {
        'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'scope' => 'openid urn:zitadel:iam:org:project:id:zitadel:aud',
        'assertion' => jwt
      })

      raise "Token request failed: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)['access_token']
    end

    def api_request(method, path, body = nil)
      uri = URI("#{ZITADEL_URL}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = case method
                when :get then Net::HTTP::Get.new(uri)
                when :post then Net::HTTP::Post.new(uri)
                when :delete then Net::HTTP::Delete.new(uri)
                end

      request['Authorization'] = "Bearer #{@token}"
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request.body = body.to_json if body

      response = http.request(request)
      raise "API request failed (#{response.code}): #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      response.body.empty? ? {} : JSON.parse(response.body)
    end

    def get_default_project
      result = api_request(:post, '/management/v1/projects/_search', { query: { limit: 10 } })
      projects = result['result'] || []
      raise 'No projects found' if projects.empty?

      projects.first['id']
    end

    def fetch_apps(project_id)
      result = api_request(:post, "/management/v1/projects/#{project_id}/apps/_search",
                           { query: { limit: 100 } })
      result['result'] || []
    end

    def create_oidc_app(project_id, name, redirect_uris)
      body = {
        name: name,
        redirectUris: redirect_uris,
        responseTypes: ['OIDC_RESPONSE_TYPE_CODE'],
        grantTypes: ['OIDC_GRANT_TYPE_AUTHORIZATION_CODE'],
        appType: 'OIDC_APP_TYPE_WEB',
        authMethodType: 'OIDC_AUTH_METHOD_TYPE_BASIC',
        postLogoutRedirectUris: [],
        version: 'OIDC_VERSION_1_0',
        devMode: false,
        accessTokenType: 'OIDC_TOKEN_TYPE_BEARER',
        accessTokenRoleAssertion: true,
        idTokenRoleAssertion: true,
        idTokenUserinfoAssertion: true,
        clockSkew: '0s'
      }

      api_request(:post, "/management/v1/projects/#{project_id}/apps/oidc", body)
    end
  end
end

def main
  options = { redirect_uris: [] }

  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: zitadel-oidc-app.rb <command> [options]'
    opts.separator ''
    opts.separator 'Commands:'
    opts.separator '  list                    List all OIDC applications'
    opts.separator '  create                  Create a new OIDC application'
    opts.separator '  delete                  Delete an OIDC application'
    opts.separator ''
    opts.separator 'Options:'

    opts.on('--name NAME', 'Application name (for create)') { |v| options[:name] = v }
    opts.on('--redirect-uri URI', 'Redirect URI (for create, can be repeated)') do |v|
      options[:redirect_uris] << v
    end
    opts.on('--app-id ID', 'Application ID (for delete)') { |v| options[:app_id] = v }
    opts.on('-h', '--help', 'Show this help') do
      puts opts
      exit
    end
  end

  parser.parse!
  command = ARGV.shift

  client = ZitadelOidcApp::Client.new

  case command
  when 'list'
    client.list_apps
  when 'create'
    raise '--name is required' unless options[:name]
    raise '--redirect-uri is required' if options[:redirect_uris].empty?

    client.create_app(options[:name], options[:redirect_uris])
  when 'delete'
    raise '--app-id is required' unless options[:app_id]

    client.delete_app(options[:app_id])
  else
    puts parser
    exit 1
  end
rescue StandardError => e
  warn "Error: #{e.message}"
  exit 1
end

main if __FILE__ == $PROGRAM_NAME
