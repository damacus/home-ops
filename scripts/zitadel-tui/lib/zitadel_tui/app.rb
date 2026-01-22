# frozen_string_literal: true

module ZitadelTui
  class App
    def initialize
      @ui = UI.new
      @config = Config.new
      @client = Client.new(config: @config)
      @authenticated = false
    end

    def run
      @ui.clear
      show_welcome

      authenticate
      main_menu
    rescue Interrupt
      @ui.newline
      @ui.info('Goodbye!')
      exit 0
    rescue StandardError => e
      @ui.error("Fatal error: #{e.message}")
      @ui.error(e.backtrace.first(5).join("\n")) if ENV['DEBUG']
      exit 1
    end

    private

    def show_welcome
      @ui.header('Zitadel Administration TUI')
      @ui.info("Version: #{VERSION}")
      @ui.info("Zitadel URL: #{@config.zitadel_url}")
      @ui.newline
    end

    def authenticate
      @ui.subheader('Authentication')

      auth_method = @ui.select_menu('Select authentication method:', [
                                      { name: '🔑 Service Account (JWT)', value: :jwt },
                                      { name: '🎫 Personal Access Token (PAT)', value: :pat }
                                    ])

      case auth_method
      when :jwt
        @ui.spinner('Authenticating with service account...') { @client.authenticate }
      when :pat
        @ui.spinner('Authenticating with PAT...') { @client.authenticate_with_pat }
      end

      @authenticated = true
      @ui.success('Authentication successful!')
      @ui.newline
    rescue AuthenticationError => e
      @ui.error("Authentication failed: #{e.message}")
      retry if @ui.yes?('Try again?')
      exit 1
    end

    def main_menu
      loop do
        @ui.clear
        @ui.header('Zitadel Administration TUI')

        choice = @ui.select_menu('Main Menu - What would you like to manage?', [
                                   { name: '📱 OIDC Applications', value: :apps },
                                   { name: '👥 Users', value: :users },
                                   { name: '🔗 Identity Providers', value: :idp },
                                   { name: '⚙️  Settings', value: :settings },
                                   { name: '🚪 Exit', value: :exit }
                                 ])

        case choice
        when :apps
          Commands::Apps.new(client: @client, ui: @ui).menu
        when :users
          Commands::Users.new(client: @client, ui: @ui).menu
        when :idp
          Commands::Idp.new(client: @client, ui: @ui).menu
        when :settings
          settings_menu
        when :exit
          @ui.info('Goodbye!')
          break
        end
      end
    end

    def settings_menu
      loop do
        @ui.clear
        @ui.header('Settings')

        @ui.info('Current configuration:')
        @ui.info("  Zitadel URL: #{@config.zitadel_url}")
        @ui.info("  Project ID: #{@config.project_id || 'Not set'}")
        @ui.info("  1Password Vault: #{@config.onepassword_vault}")
        @ui.newline

        choice = @ui.select_menu('Settings', [
                                   { name: '🌐 Change Zitadel URL', value: :url },
                                   { name: '📁 Set Project ID', value: :project },
                                   { name: '🔐 Change 1Password Vault', value: :vault },
                                   { name: '💾 Save configuration', value: :save },
                                   { name: '← Back to main menu', value: :back }
                                 ])

        case choice
        when :url
          new_url = @ui.ask('Zitadel URL:', default: @config.zitadel_url)
          @config.config.set(:zitadel_url, value: new_url)
          @ui.success("URL updated to: #{new_url}")
        when :project
          new_project = @ui.ask('Project ID:')
          @config.project_id = new_project
          @ui.success("Project ID set to: #{new_project}")
        when :vault
          new_vault = @ui.ask('1Password Vault:', default: @config.onepassword_vault)
          @config.config.set(:onepassword_vault, value: new_vault)
          @ui.success("Vault updated to: #{new_vault}")
        when :save
          @config.save
          @ui.success('Configuration saved!')
        when :back
          break
        end

        @ui.press_any_key unless choice == :back
      end
    end
  end
end
