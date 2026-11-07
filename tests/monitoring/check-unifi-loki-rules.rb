#!/usr/bin/env ruby
# Run against an isolated Loki at LOKI_URL; this writes synthetic log events.
require "json"
require "net/http"
require "uri"
require "yaml"

base = ENV.fetch("LOKI_URL")
raise "Use a loopback Loki instance" unless ["127.0.0.1", "localhost", "::1"].include?(URI(base).host)

rules_file = File.expand_path("../../kubernetes/apps/monitoring/unifi-logs/app/rules.yaml", __dir__)
rules = YAML.safe_load(YAML.safe_load_file(rules_file).fetch("data").fetch("unifi-os.yaml")).fetch("groups").first.fetch("rules")
timestamp = (Time.now.to_r * 1_000_000_000).to_i.to_s
fixtures = {
  "storage" => "kernel: blk_update_request: I/O error, dev sda",
  "filesystem" => "kernel: EXT4-fs error: filesystem corrupt",
  "journal" => "kernel: Aborting journal on device sda1-8",
  "readonly" => "kernel: EXT4-fs: Remounting filesystem read-only",
  "parity" => "kernel: al_eth 0000:00:00.0 eth9: ETH(0)-MAC 1G TX Data FIFO SRAM Parity Error: 1",
  "oom" => "kernel: Out of memory: Killed process 123",
  "mdio" => "kernel: MDIO bus timeout during boot",
  "historical" => "kernel: EXT4-fs error: filesystem corrupt"
}
streams = fixtures.map do |device, message|
  {stream: {job: "unifi-os", device: device, log_origin: device == "historical" ? "historical" : "live"}, values: [[timestamp, message]]}
end
uri = URI.join(base, "/loki/api/v1/push")
response = Net::HTTP.post(uri, JSON.generate(streams: streams), "Content-Type" => "application/json")
raise "Fixture push failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

expected = {
  "UnifiStorageIOFailure" => ["storage"],
  "UnifiFilesystemCorruption" => ["filesystem", "journal", "readonly"],
  "UnifiEthernetSramParity" => ["parity"],
  "UnifiOutOfMemoryKill" => ["oom"]
}
rules.each do |rule|
  uri = URI.join(base, "/loki/api/v1/query")
  uri.query = URI.encode_www_form(query: rule.fetch("expr"))
  response = Net::HTTP.get_response(uri)
  raise "#{rule.fetch("alert")}: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)
  result = JSON.parse(response.body).fetch("data").fetch("result").map { |item| item.fetch("metric").fetch("device") }.sort
  raise "#{rule.fetch("alert")}: expected #{expected.fetch(rule.fetch("alert"))}, got #{result}" unless result == expected.fetch(rule.fetch("alert"))
  puts "#{rule.fetch("alert")}: #{result.join(", ")}"
end
