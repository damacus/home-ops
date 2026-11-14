# frozen_string_literal: true

module Shared
  class Navbar < Bridgetown::Component
    attr_reader :metadata, :resource, :strategy

    def initialize(metadata:, resource:)
      @metadata, @resource = metadata, resource
      @strategy = Willamette.navbar(
        self, logo: nil, site_title: metadata.title, search: true,
        nav_links: [
          Willamette.link(title: "The setup", url: "/setup/"),
          Willamette.link(title: "In progress", url: "/in-progress/"),
          Willamette.link(title: "Debugging", url: "/debugging/"),
          Willamette.link(title: "History", url: "/history/")
        ]
      )
    end
  end

  class Sidebar < Bridgetown::Component
    attr_reader :metadata, :resource, :strategy

    def initialize(metadata:, resource:)
      @metadata, @resource = metadata, resource
      @strategy = Willamette.sidebar(
        self, description: metadata.description,
        explore_links: [
          Willamette.link(title: "Home", url: "/"),
          Willamette.link(title: "The setup", url: "/setup/"),
          Willamette.link(title: "In progress", url: "/in-progress/"),
          Willamette.link(title: "Debugging", url: "/debugging/"),
          Willamette.link(title: "History", url: "/history/"),
          Willamette.link(title: "Service guides", url: "/applications/"),
          Willamette.link(title: "Operating guides", url: "/operations/"),
          Willamette.link(title: "Provisioning", url: "/provisioning/"),
          Willamette.link(title: "Reference", url: "/reference/")
        ], subscribe: false
      )
    end
  end
end
