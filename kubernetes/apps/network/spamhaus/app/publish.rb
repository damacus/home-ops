#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "ipaddr"
require "json"
require "net/http"
require "tmpdir"
require "uri"

# Publish validated Spamhaus feeds as one atomic generation.
module Spamhaus
  ROOT = ENV.fetch("PUBLISH_ROOT", "/data")
  MAX_BYTES = 4 * 1024 * 1024
  FEED_URL = "https://www.spamhaus.org/drop/drop_v%d.json"

  # Preserve Python 3.15 ipaddress network.is_global classification, including
  # its IANA special-purpose exceptions and shared IPv4 address space.
  # https://docs.python.org/3.15/library/ipaddress.html#ipaddress.IPv4Address.is_global
  NON_GLOBAL = {
    4 => %w[0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16
            172.16.0.0/12 192.0.0.0/24 192.0.0.170/31 192.0.2.0/24
            192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
            240.0.0.0/4 255.255.255.255/32],
    6 => %w[::1/128 ::/128 ::ffff:0:0/96 64:ff9b:1::/48 100::/64
            2001::/23 2001:db8::/32 2002::/16 3fff::/20 fc00::/7 fe80::/10]
  }.transform_values { |ranges| ranges.map { |cidr| IPAddr.new(cidr) }.freeze }.freeze
  GLOBAL_EXCEPTIONS = {
    4 => %w[192.0.0.9/32 192.0.0.10/32],
    6 => %w[2001:1::1/128 2001:1::2/128 2001:3::/32 2001:4:112::/48
            2001:20::/28 2001:30::/28]
  }.transform_values { |ranges| ranges.map { |cidr| IPAddr.new(cidr) }.freeze }.freeze
  SHARED_V4 = IPAddr.new("100.64.0.0/10")

  def self.global_network?(network, version)
    first = network.to_range.first
    last = network.to_range.last
    return false if version == 4 && SHARED_V4.include?(first) && SHARED_V4.include?(last)

    private_network = NON_GLOBAL.fetch(version).any? { |range| range.include?(first) && range.include?(last) }
    exception = GLOBAL_EXCEPTIONS.fetch(version).any? { |range| range.include?(first) || range.include?(last) }
    !private_network || exception
  end

  def self.convert(data, version)
    networks = []
    metadata = nil
    data.each_line do |line|
      entry = JSON.parse(line)
      if entry["type"] == "metadata"
        raise "duplicate feed metadata" if metadata

        metadata = entry
        next
      end
      raise "unexpected feed record" unless entry["type"].nil? && metadata.nil?

      cidr = entry.fetch("cidr")
      address = cidr.split("/", -1).first
      network = IPAddr.new(cidr)
      raise "network has host bits set" unless IPAddr.new(address) == network

      actual_version = network.ipv4? ? 4 : 6
      raise "unexpected network in Spamhaus feed" unless actual_version == version && global_network?(network, version)

      # IPAddr accepts a numeric prefix or a contiguous address mask, as did
      # ipaddress.ip_network. Derive the effective prefix after parsing it.
      prefix_length = network.prefix
      raise "unexpectedly broad Spamhaus network" if prefix_length < (version == 4 ? 8 : 16)

      networks << "#{network}/#{prefix_length}"
    end
    unless !networks.empty? && metadata && metadata["records"] == networks.length
      raise "incomplete Spamhaus feed"
    end

    "#{networks.join("\n")}\n"
  end

  def self.download(version)
    download_uri(URI(format(FEED_URL, version)))
  end

  # Read directly into memory: open-uri spills larger responses into /tmp,
  # which is deliberately unwritable in the publisher container.
  def self.download_uri(uri, redirects = 10)
    raise "unsupported feed URL" unless %w[http https].include?(uri.scheme)

    data = +"".b
    location = nil
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 30, read_timeout: 30) do |http|
      http.request(Net::HTTP::Get.new(uri)) do |response|
        if response.is_a?(Net::HTTPRedirection)
          location = response.fetch("location")
        else
          response.value
          response.read_body do |chunk|
            raise "feed exceeds size limit" if data.bytesize + chunk.bytesize > MAX_BYTES

            data << chunk
          end
        end
      end
    end
    if location
      raise "too many feed redirects" if redirects.zero?

      return download_uri(URI.join(uri, location), redirects - 1)
    end

    data
  end

  def self.publish
    feeds = [4, 6].to_h do |version|
      raw = download(version)
      [version, [raw, convert(raw, version)]]
    end
    FileUtils.mkdir_p(ROOT)
    generation = Dir.mktmpdir("generation-", ROOT)
    feeds.each do |version, (raw, cidrs)|
      File.binwrite(File.join(generation, "drop_v#{version}.json"), raw)
      File.write(File.join(generation, "drop_v#{version}.txt"), cidrs)
    end
    File.write(File.join(generation, "metrics.txt"), "spamhaus_last_success_timestamp_seconds #{Time.now.to_i}\n")
    link = File.join(ROOT, ".next")
    File.unlink(link) if File.exist?(link) || File.symlink?(link)
    File.symlink(File.basename(generation), link)
    File.rename(link, File.join(ROOT, "current"))
    Dir.glob(File.join(ROOT, "generation-*")).each do |old|
      FileUtils.remove_entry(old) if old != generation && File.directory?(old) && Time.now - File.mtime(old) > 7 * 86_400
    end
  end
end

Spamhaus.publish if $PROGRAM_NAME == __FILE__
