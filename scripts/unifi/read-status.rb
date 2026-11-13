#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only UniFi diagnostics for mesh/backhaul investigations.
require 'base64'
require 'json'
require 'net/http'
require 'open3'
require 'openssl'
require 'optparse'
require 'time'
require 'uri'

module HomeOps
  module UnifiStatus
    DEFAULTS = {
      controller: 'https://192.168.1.254', site: 'default', secret_namespace: 'network',
      secret_name: 'external-dns-unifi-secret', secret_key: 'api-key',
      devices: 'U6-LR,U6-Mesh,U6 Pro,USW-Lite-8-PoE',
      watch_ips: 'U6-LR=192.168.1.155,U6-Mesh=192.168.1.109,USW-Lite-8-PoE=192.168.1.38,Garage=192.168.1.168',
      client_macs: '70:a7:41:5f:13:d9'
    }.freeze

    class Error < StandardError; end

    def self.csv(value)
      value.split(',').map(&:strip).reject(&:empty?)
    end

    def self.watch_ips(value)
      csv(value).map do |item|
        separator = item.include?('=') ? '=' : ':'
        pair = item.include?(separator) ? item.split(separator, 2) : [item, item]
        pair.map(&:strip)
      end
    end

    def self.timestamp(value)
      value.is_a?(Numeric) && value.positive? ? Time.at(value).utc.iso8601 : '-'
    end

    def self.value_or_dash(value)
      return '-' if value.nil? || value == ''
      return 'True' if value == true
      return 'False' if value == false
      value.to_s
    end

    def self.table(output, title, headers, rows)
      output.puts title
      text = rows.map { |row| row.map { |v| value_or_dash(v) } }
      widths = headers.each_with_index.map { |h, i| ([h.length] + text.map { |row| row[i].length }).max }
      output.puts headers.each_with_index.map { |h, i| h.ljust(widths[i]) }.join('  ')
      output.puts widths.map { |w| '-' * w }.join('  ')
      text.each { |row| output.puts row.each_with_index.map { |v, i| v.ljust(widths[i]) }.join('  ') }
      output.puts
    end

    def self.api_key(options)
      out, err, status = Open3.capture3('kubectl', 'get', 'secret', '-n', options[:secret_namespace], options[:secret_name], '-o', "jsonpath={.data.#{options[:secret_key]}}")
      raise Error, err.strip.empty? ? 'kubectl secret read failed' : err.strip unless status.success?
      Base64.strict_decode64(out.strip).strip
    rescue ArgumentError
      raise Error, 'base64 decode failed'
    end

    class Client
      def initialize(controller, site, key)
        @controller, @site, @key = controller.sub(%r{/+\z}, ''), site, key
      end

      def get(resource)
        url = URI.parse("#{@controller}/proxy/network/api/s/#{@site}/stat/#{resource}")
        request = Net::HTTP::Get.new(url)
        request['Accept'] = 'application/json'
        request['X-API-KEY'] = @key
        # The private controller uses its appliance certificate, matching the previous client.
        response = Net::HTTP.start(url.host, url.port, use_ssl: url.scheme == 'https',
                                   verify_mode: OpenSSL::SSL::VERIFY_NONE, open_timeout: 20, read_timeout: 20) { |http| http.request(request) }
        raise Error, "UniFi request failed for #{url}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
        JSON.parse(response.body).fetch('data', [])
      rescue JSON::ParserError, URI::InvalidURIError, IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError => e
        raise Error, "UniFi request failed: #{e.message}"
      end
    end

    def self.ping(targets)
      wait = RUBY_PLATFORM.include?('darwin') ? '1000' : '1'
      targets.map do |name, ip|
        out, err, status = Open3.capture3('ping', '-c', '1', '-W', wait, ip)
        detail = if status.success?
                   'reachable'
                 else
                   message = [out.strip, err.strip].reject(&:empty?).join("\n")
                   if message.include?('No route to host')
                     'no route to host'
                   elsif message.match?(/100(?:\.0)?% packet loss/)
                     'timeout'
                   else
                     message.lines.last&.strip || "ping exited #{status.exitstatus}"
                   end
                 end
        { name: name, ip: ip, ok: status.success?, detail: detail }
      end
    end

    def self.print_report(output, devices, clients, pings)
      output.puts "Collected at #{Time.now.utc.iso8601}\n\n"
      table(output, 'Devices', %w[name state ip model version last_seen disconnected_at], devices.map do |d|
        [d['name'], { 0 => 'offline', 1 => 'online', 11 => 'adopting/pending' }.fetch(d['state'], value_or_dash(d['state'])), d['ip'], d['model'], d['version'], timestamp(d['last_seen']), timestamp(d['disconnected_at'])]
      end)
      radios = devices.flat_map { |d| (d['radio_table'] || []).map { |r| [d['name'], *%w[radio name channel ht tx_power tx_power_mode vwire_enabled].map { |k| r[k] }] } }
      table(output, 'AP radios', %w[device band radio channel width tx_power tx_mode mesh], radios)
      uplinks = devices.filter_map do |d|
        u = d['uplink'] || {}
        next unless u['type'] == 'wireless'
        [d['name'], u['uplink_device_name'] || u['uplink_mac'], *%w[radio channel signal rssi tx_rate rx_rate is_mesh_v3].map { |k| u[k] }]
      end
      table(output, 'Active wireless uplinks', %w[device parent band channel signal rssi tx_rate rx_rate mesh_v3], uplinks)
      peers = devices.flat_map { |d| (d['uplink_table'] || []).map { |p| [d['name'], *%w[mac radio channel signal rssi noise].map { |k| p[k] }] } }
      table(output, 'Wireless peer observations', %w[observer peer_mac band channel signal rssi noise], peers)
      ports = devices.flat_map do |d|
        (d['port_table'] || []).select { |p| [1, 4].include?(p['port_idx']) }.map do |p|
          [d['name'], *%w[port_idx name up speed poe_power poe_voltage rx_errors tx_errors rx_dropped tx_dropped link_down_count].map { |k| p[k] }]
        end
      end
      table(output, 'Switch ports of interest', %w[switch port name up speed poe_w poe_v rx_err tx_err rx_drop tx_drop link_down], ports) unless ports.empty?
      unless clients.empty?
        rows = clients.map { |c| [*%w[name hostname ip mac ap_mac sw_mac uptime].map { |k| c[k] }, timestamp(c['last_seen'])] }
        table(output, 'Clients of interest', %w[name hostname ip mac ap_mac sw_mac uptime last_seen], rows)
      end
      table(output, 'Reachability', %w[name ip status detail], pings.map { |p| [p[:name], p[:ip], p[:ok] ? 'ok' : 'fail', p[:detail]] }) unless pings.empty?
    end

    def self.sorted(value)
      case value
      when Hash then value.keys.sort_by(&:to_s).to_h { |k| [k, sorted(value[k])] }
      when Array then value.map { |v| sorted(v) }
      else value
      end
    end

    def self.run_cli(args, stdout: $stdout, stderr: $stderr)
      options = DEFAULTS.dup
      parser = OptionParser.new do |o|
        o.banner = 'Read-only UniFi diagnostics for mesh/backhaul investigations.'
        DEFAULTS.each_key do |key|
          o.on("--#{key.to_s.tr('_', '-')} VALUE") { |v| options[key] = v }
        end
        o.on('--json', 'Print raw selected data as JSON') { options[:json] = true }
        o.on('--no-ping', 'Skip local ICMP reachability checks') { options[:no_ping] = true }
        o.on('-h', '--help') { stdout.puts o; return 0 }
      end
      parser.parse!(args)
      raise OptionParser::InvalidArgument, args.join(' ') unless args.empty?
      names = csv(options[:devices])
      targets = watch_ips(options[:watch_ips])
      macs = csv(options[:client_macs].downcase)
      key = api_key(options)
      client = Client.new(options[:controller], options[:site], key)
      by_name = client.get('device').to_h { |d| [d['name'].to_s, d] }
      devices = names.filter_map { |n| by_name[n] }
      ips = targets.map(&:last)
      clients = client.get('sta').select { |c| ips.include?(c['ip'].to_s) || macs.include?(c['mac'].to_s.downcase) }
      pings = options[:no_ping] ? [] : ping(targets)
      if options[:json]
        stdout.puts JSON.pretty_generate(sorted({ collected_at: Time.now.utc.iso8601, devices: devices, clients: clients, reachability: pings }))
      else
        print_report(stdout, devices, clients, pings)
      end
      0
    rescue OptionParser::ParseError => e
      stderr.puts e.message
      2
    rescue Error, SystemCallError => e
      stderr.puts "[FAIL] #{e.message}"
      1
    end
  end
end

exit HomeOps::UnifiStatus.run_cli(ARGV) if $PROGRAM_NAME == __FILE__
