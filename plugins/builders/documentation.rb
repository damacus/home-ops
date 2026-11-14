# frozen_string_literal: true

class Builders::Documentation < SiteBuilder
  def build
    hook :site, :post_read do |site|
      @sources = {}
      site.collections.each_value do |collection|
        collection.resources.reject! do |resource|
          origin = resource.model.origin
          origin.respond_to?(:manifest) && origin.manifest.origin == Willamette
        end
        collection.resources.each do |resource|
          next unless resource.content.is_a?(String)
          resource.data.layout ||= "documentation"
          heading = resource.content[/^#\s+(.+)$/, 1]
          resource.data.title = heading if heading
          @sources[source_path(resource)] = resource.relative_url
        end
      end
      site.data.guide_index = site.resources.filter_map do |resource|
        next unless resource.data.doc_type
        if resource.data.doc_type == "project" && !%w[active paused completed].include?(resource.data.status)
          raise "Unknown project status in #{source_path(resource)}: #{resource.data.status.inspect}"
        end

        {
          title: resource.data.title, url: resource.relative_url,
          description: resource.data.description, doc_type: resource.data.doc_type,
          status: resource.data.status, reviewed: resource.data.reviewed
        }
      end.sort_by { |guide| guide[:title].to_s.downcase }
    end

    # Resolve repository-relative Markdown links after rendering, leaving code examples unchanged.
    inspect_html do |document, resource|
      article = document.at_css("article")
      next unless article

      source = source_path(resource)
      article.css("a[href], img[src]").each do |node|
        attribute = node.name == "img" ? "src" : "href"
        url = node[attribute]
        next if url.nil? || url.empty? || url.match?(%r!\A(?:[a-z][a-z0-9+.-]*:|/|\#)!i)

        path, fragment = url.split("#", 2)
        target = File.expand_path(path, File.dirname(source))
        next unless target.start_with?("#{site.root_dir}/")

        resolved = @sources[target]
        unless resolved
          relative = target.delete_prefix("#{site.root_dir}/")
          kind = File.directory?(target) ? "tree" : "blob"
          resolved = if attribute == "src"
                       "https://raw.githubusercontent.com/damacus/home-ops/main/#{relative}"
                     else
                       "https://github.com/damacus/home-ops/#{kind}/main/#{relative}"
                     end
        end
        node[attribute] = [resolved, fragment].compact.join("#")
      end

      add_contents(document, article)
    end
  end

  private

  def add_contents(document, article)
    headings = article.css("h2[id]")
    return if headings.length < 4

    nav = document.create_element("nav", "aria-label": "On this page")
    list = document.create_element("ul")
    headings.each do |heading|
      item = document.create_element("li")
      # Willamette adds a permalink marker to headings before this inspector runs.
      title = heading.text.sub(/\s*#\s*\z/, "")
      item << document.create_element("a", title, href: "##{heading['id']}")
      list << item
    end
    nav << list

    sidebar = document.at_css('aside[slot="sidebar-end"]')
    sidebar.remove_attribute("hidden")
    sidebar.inner_html = ""
    sidebar << document.create_element("h2", "On this page")
    sidebar << nav
    sidebar["class"] = "page-contents"
    sidebar["data-pagefind-ignore"] = ""
    document.css('main > .show-mid-screen, aside[slot="sidebar-end"] > .show-mid-screen').each(&:remove)

    details = document.create_element("details", class: "page-contents-mobile", "data-pagefind-ignore": "")
    details << document.create_element("summary", "On this page")
    details << nav.dup
    introduction = article.at_css("h1 + p") || article.at_css("h1")
    introduction.add_next_sibling(details) if introduction
  end

  def source_path(resource)
    origin = resource.model.origin
    return origin.original_path.to_s if origin.respond_to?(:original_path)

    File.expand_path(resource.relative_path.to_s, site.source)
  end
end
