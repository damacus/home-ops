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
          resolved = "https://github.com/damacus/home-ops/#{kind}/main/#{relative}"
        end
        node[attribute] = [resolved, fragment].compact.join("#")
      end
    end
  end

  private

  def source_path(resource)
    origin = resource.model.origin
    return origin.original_path.to_s if origin.respond_to?(:original_path)

    File.expand_path(resource.relative_path.to_s, site.source)
  end
end
