# frozen_string_literal: true

module ZitadelTui
  module Commands
    class Users
      PREDEFINED_USERS = [
        { email: 'dan.m.webb@gmail.com', first_name: 'Dan', last_name: 'Webb', admin: true },
        { email: '28lauracummings@gmail.com', first_name: 'Laura', last_name: 'Cummings', admin: false },
        { email: 'webbglor@googlemail.com', first_name: 'Gloria', last_name: 'Webb', admin: false },
        { email: 'gtxthor37@gmail.com', first_name: 'Gordon', last_name: 'Webb', admin: false },
        { email: 'dan.webb@damacus.io', first_name: 'Daniel', last_name: 'Webb', admin: true }
      ].freeze

      def initialize(client:, ui:)
        @client = client
        @ui = ui
      end

      def menu
        loop do
          @ui.clear
          @ui.header('User Management')

          choice = @ui.select_menu('What would you like to do?', [
                                     { name: '📋 List all users', value: :list },
                                     { name: '➕ Create new user', value: :create },
                                     { name: '👑 Create admin user', value: :create_admin },
                                     { name: '🔑 Grant IAM_OWNER role', value: :grant_admin },
                                     { name: '🚀 Quick setup (predefined users)', value: :quick_setup },
                                     { name: '← Back to main menu', value: :back }
                                   ])

          case choice
          when :list then list_users
          when :create then create_user
          when :create_admin then create_admin_user
          when :grant_admin then grant_admin_role
          when :quick_setup then quick_setup
          when :back then break
          end

          @ui.press_any_key unless choice == :back
        end
      end

      private

      def list_users
        @ui.subheader('Users')

        users = @ui.spinner('Fetching users...') { @client.list_users }

        if users.empty?
          @ui.warning('No users found')
          return
        end

        rows = users.map do |user|
          human = user['human']
          [
            user['userName'],
            user['id'],
            human&.dig('profile',
                       'displayName') || "#{human&.dig('profile', 'firstName')} #{human&.dig('profile', 'lastName')}",
            human&.dig('email', 'email') || 'N/A',
            user['state']
          ]
        end

        @ui.table(%w[Username UserID DisplayName Email State], rows)
      end

      def create_user
        @ui.subheader('Create New User')

        data = @ui.collect do
          key(:email).ask('Email address:', required: true) do |q|
            q.validate(/\A[\w+\-.]+@[a-z\d-]+(\.[a-z\d-]+)*\.[a-z]+\z/i, 'Invalid email format')
          end
          key(:first_name).ask('First name:', required: true)
          key(:last_name).ask('Last name:', required: true)
          key(:username).ask('Username (leave blank to use email prefix):')
        end

        username = data[:username].to_s.empty? ? nil : data[:username]

        result = @ui.spinner('Creating user...') do
          @client.create_human_user(
            email: data[:email],
            first_name: data[:first_name],
            last_name: data[:last_name],
            username: username
          )
        end

        @ui.success('User created successfully!')
        @ui.info("User ID: #{result['userId']}")

        grant_role_to_user(result['userId']) if @ui.yes?('Grant admin (IAM_OWNER) role to this user?')
      rescue ZitadelTui::ApiError => e
        @ui.error("Failed to create user: #{e.message}")
      end

      def create_admin_user
        @ui.subheader('Create Admin User')

        @ui.info('This will create a local admin user with password authentication.')
        @ui.warning('The user will be required to change their password on first login.')

        data = @ui.collect do
          key(:username).ask('Username:', default: 'admin', required: true)
          key(:first_name).ask('First name:', default: 'Admin', required: true)
          key(:last_name).ask('Last name:', default: 'User', required: true)
          key(:email).ask('Email:', required: true) do |q|
            q.validate(/\A[\w+\-.]+@[a-z\d-]+(\.[a-z\d-]+)*\.[a-z]+\z/i, 'Invalid email format')
          end
          key(:password).mask('Temporary password:', required: true) do |q|
            q.validate(/\A.{8,}\z/, 'Password must be at least 8 characters')
          end
        end

        result = @ui.spinner('Creating admin user...') do
          @client.import_human_user(
            username: data[:username],
            first_name: data[:first_name],
            last_name: data[:last_name],
            email: data[:email],
            password: data[:password],
            password_change_required: true
          )
        end

        @ui.success('Admin user created successfully!')
        @ui.credentials_box('Admin Login Credentials', {
                              'URL' => "#{@client.config.zitadel_url}/ui/console/",
                              'Username' => data[:username],
                              'Password' => data[:password]
                            })
        @ui.warning('Password change will be required on first login')

        grant_role_to_user(result['userId']) if @ui.yes?('Grant IAM_OWNER role to this user?')
      rescue ZitadelTui::ApiError => e
        @ui.error("Failed to create admin user: #{e.message}")
      end

      def grant_admin_role
        @ui.subheader('Grant IAM_OWNER Role')

        users = @ui.spinner('Fetching users...') { @client.list_users }

        if users.empty?
          @ui.warning('No users found')
          return
        end

        choices = users.map do |user|
          human = user['human']
          display = "#{user['userName']} - #{human&.dig('email', 'email') || 'N/A'}"
          { name: display, value: user }
        end

        selected = @ui.select_menu('Select user to grant IAM_OWNER role:', choices)

        @ui.warning("This will grant full instance administration rights to #{selected['userName']}")
        return unless @ui.yes?('Proceed?')

        grant_role_to_user(selected['id'])
      end

      def grant_role_to_user(user_id)
        @ui.spinner('Granting IAM_OWNER role...') do
          @client.grant_iam_owner(user_id)
        end

        @ui.success('IAM_OWNER role granted successfully!')
        @ui.info('The user now has full instance administration rights.')
        @ui.info('Log out and log back in to see the changes.')
      rescue ZitadelTui::ApiError => e
        @ui.error("Failed to grant role: #{e.message}")
      end

      def quick_setup
        @ui.subheader('Quick Setup - Predefined Users')

        @ui.info('The following users will be created:')
        @ui.newline

        rows = PREDEFINED_USERS.map do |user|
          [user[:email], "#{user[:first_name]} #{user[:last_name]}", user[:admin] ? 'Yes' : 'No']
        end
        @ui.table(%w[Email Name Admin], rows)

        @ui.newline
        return unless @ui.yes?('Create these users?')

        PREDEFINED_USERS.each do |user_data|
          result = @ui.spinner("Creating #{user_data[:email]}...") do
            @client.create_human_user(
              email: user_data[:email],
              first_name: user_data[:first_name],
              last_name: user_data[:last_name]
            )
          end

          @ui.success("Created: #{user_data[:email]} (ID: #{result['userId']})")

          if user_data[:admin]
            @ui.spinner("Granting admin role to #{user_data[:email]}...") do
              @client.grant_iam_owner(result['userId'])
            end
            @ui.success("Granted IAM_OWNER to #{user_data[:email]}")
          end
        rescue ZitadelTui::ApiError => e
          @ui.error("Failed to create #{user_data[:email]}: #{e.message}")
        end

        @ui.newline
        @ui.success('Quick setup complete!')
        @ui.info('Users can now log in via Google OAuth or link their Google accounts.')
      end
    end
  end
end
