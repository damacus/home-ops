# frozen_string_literal: true

require_relative 'zitadel_tui/version'
require_relative 'zitadel_tui/config'
require_relative 'zitadel_tui/client'
require_relative 'zitadel_tui/ui'
require_relative 'zitadel_tui/commands/apps'
require_relative 'zitadel_tui/commands/users'
require_relative 'zitadel_tui/commands/idp'

module ZitadelTui
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class ApiError < Error; end
end
