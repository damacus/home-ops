# frozen_string_literal: true

module Shared
  class Navbar < Bridgetown::Component
    attr_reader :metadata, :resource, :strategy

    def initialize(metadata:, resource:)
      @metadata, @resource = metadata, resource
      @strategy = Willamette.navbar(
        self, logo: nil, site_title: metadata.title, search: true,
        nav_links: [
          Willamette.link(title: "Getting started", url: "/"),
          Willamette.link(title: "Applications", url: "/applications/"),
          Willamette.link(title: "Helm charts", url: "/operations/helm-charts/")
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
          Willamette.link(title: "Getting started", url: "/"),
          Willamette.link(title: "Operations", url: "/operations/"),
          Willamette.link(title: "Provisioning", url: "/provisioning/"),
          Willamette.link(title: "Applications", url: "/applications/"),
          Willamette.link(title: "Helm charts", url: "/operations/helm-charts/"),
          Willamette.link(title: "Flashing Radxa 5B+", url: "/flashing/"),
          Willamette.link(title: "Zitadel setup", url: "/zitadel-setup/"),
          Willamette.link(title: "Zitadel migration", url: "/docs/zitadel-migration/")
        ], subscribe: false
      )
    end
  end
end
