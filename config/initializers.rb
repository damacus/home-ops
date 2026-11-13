# frozen_string_literal: true

Bridgetown.configure do |config|
  url "https://damacus.github.io"
  base_path "/home-ops"
  source "site_docs"
  destination "output"
  template_engine "erb"
  timezone "Europe/London"
  permalink "pretty"
  html_inspector_parser "nokolexbor"

  init :willamette, bypass_style_guide: true
  collections do
    operations do
      output true
      permalink "/operations/:path/"
    end
    provisioning do
      output true
      permalink "/provisioning/:path/"
    end
    applications do
      output true
      permalink "/applications/:path/"
    end
  end

  init :external_sources,
       contents: { operations: "docs", provisioning: "provisioning", applications: "kubernetes/apps" },
       filters: {
         operations: ->(name, path) { File.directory?(path) || name.end_with?(".md") },
         provisioning: ->(name, path) { File.directory?(path) ? !path.include?("/armbian-build") : name.end_with?(".md") },
         applications: ->(name, path) { !path.include?("/medtracker-canary") && (File.directory?(path) || name == "README.md") }
       }
end
