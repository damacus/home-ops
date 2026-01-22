# frozen_string_literal: true

require 'tty-config'

module ZitadelTui
  class Config
    DEFAULT_URL = 'https://zitadel.damacus.io'
    SA_KEY_FILE = '/tmp/zitadel-sa.json'
    SA_SECRET_NAME = 'zitadel-admin-sa'
    SA_SECRET_NAMESPACE = 'authentication'
    SA_SECRET_KEY = 'zitadel-admin-sa.json'
    PAT_SECRET_NAME = 'zitadel-admin-sa-pat'
    PAT_SECRET_KEY = 'pat'
    GOOGLE_IDP_SECRET = 'zitadel-google-idp'

    attr_reader :config

    def initialize
      @config = TTY::Config.new
      @config.filename = 'zitadel-tui'
      @config.extname = '.yml'
      @config.append_path(Dir.home)
      @config.append_path(Dir.pwd)

      set_defaults
      load_config
    end

    def zitadel_url
      @config.fetch(:zitadel_url, default: DEFAULT_URL)
    end

    def project_id
      @config.fetch(:project_id)
    end

    def project_id=(value)
      @config.set(:project_id, value: value)
    end

    def sa_key_file
      @config.fetch(:sa_key_file, default: SA_KEY_FILE)
    end

    def onepassword_vault
      @config.fetch(:onepassword_vault, default: 'home-ops')
    end

    def save
      @config.write(force: true)
    end

    private

    def set_defaults
      @config.set(:zitadel_url, value: DEFAULT_URL)
      @config.set(:sa_key_file, value: SA_KEY_FILE)
      @config.set(:onepassword_vault, value: 'home-ops')
    end

    def load_config
      @config.read if @config.exist?
    rescue TTY::Config::ReadError
      # Config file doesn't exist yet, use defaults
    end
  end
end
