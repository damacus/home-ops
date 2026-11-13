#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/home_ops/cluster_health/core'
require_relative '../lib/home_ops/cluster_health/monitoring'
require_relative '../lib/home_ops/cluster_health/edge'

module HomeOps
  module ClusterHealth
    CHECKS = { 'nodes' => :nodes, 'kube-vip' => :kube_vip, 'cilium' => :cilium, 'pods' => :pods,
               'deployments' => :deployments, 'gitops-health' => :gitops, 'external-secrets-health' => :external_secrets,
               'service-account-health' => :service_accounts, 'cnpg-health' => :cnpg_clusters, 'cnpg-backups' => :cnpg_backups,
               'grafana-alerts' => :grafana_alerts, 'edge-smoke' => :edge_smoke, 'log-noise' => :log_noise }.freeze

    def self.run_cli(args, stdout: $stdout, stderr: $stderr)
      usage = "usage: cluster-health <check> [options]\nchecks: #{CHECKS.keys.join(', ')}"
      if args.empty?
        stderr.puts usage
        return 2
      end
      command = args.shift
      options = { format: 'text', timeout: 45.0, period: '1h', top: 20 }
      args.each do |a|
        raise OptionParser::InvalidOption, '--json was removed; use --format=ndjson' if a.match?(/\A--json(?:=|\z)/)
        raise OptionParser::InvalidOption, '--workers was removed; Task now composes checks deterministically' if a.match?(/\A--workers(?:=|\z)/)
      end
      parser = OptionParser.new do |o|
        o.banner = usage
        o.on('--format FORMAT', 'output format: text or ndjson') { |v| options[:format] = v }
        %w[verbose raw notify skip-http3 include-esphome-canary].each do |flag|
          o.on("--#{flag}[=BOOL]") do |v|
            raise OptionParser::InvalidArgument, "invalid boolean #{v.inspect}" unless v.nil? || %w[true false 1 0 t f TRUE FALSE True False T F].include?(v)
            options[flag.tr('-', '_').to_sym] = v.nil? || %w[true 1 t TRUE True T].include?(v)
          end
        end
        o.on('--timeout DURATION', 'timeout for each subprocess') do |v|
          remaining = v.sub(/\A[+-]/, '')
          seconds = 0.0
          units = { 'ns' => 1e-9, 'us' => 1e-6, 'µs' => 1e-6, 'μs' => 1e-6, 'ms' => 0.001, 's' => 1, 'm' => 60, 'h' => 3600 }
          unless remaining == '0'
            raise OptionParser::InvalidArgument, 'timeout must be a duration such as 45s' if remaining.empty?
            until remaining.empty?
              match = /\A(\d+(?:\.\d*)?|\.\d+)(ns|us|µs|μs|ms|s|m|h)/.match(remaining)
              raise OptionParser::InvalidArgument, 'timeout must be a duration such as 45s' unless match
              seconds += match[1].to_f * units.fetch(match[2])
              remaining = remaining[match[0].length..]
            end
          end
          options[:timeout] = v.start_with?('-') ? -seconds : seconds
        end
        o.on('--period PERIOD') { |v| options[:period] = v }
        o.on('--top COUNT', Integer) { |v| options[:top] = v }
        %w[esphome-websocket-path esphome-websocket-contains].each { |flag| o.on("--#{flag} VALUE") { |v| options[flag.tr('-', '_').to_sym] = v } }
        o.on('-h', '--help') { stdout.puts o; return 0 }
      end
      parser.parse!(args)
      raise OptionParser::InvalidArgument, "unexpected arguments: #{args.join(' ')}" unless args.empty?
      raise OptionParser::InvalidArgument, "unsupported format #{options[:format].inspect}; use text or ndjson" unless %w[text ndjson].include?(options[:format])
      raise OptionParser::InvalidArgument, 'timeout must be greater than zero' unless options[:timeout].positive?
      raise OptionParser::InvalidArgument, 'top must be greater than zero' unless options[:top].positive?
      raise OptionParser::InvalidArgument, "invalid period #{options[:period].inspect}; use a positive duration such as 1h or 30m" unless options[:period].match?(/\A[1-9][0-9]*[smhdw]\z/)
      unless CHECKS.key?(command)
        stderr.puts "unknown check #{command.inspect}", usage
        return 2
      end
      runner = Runner.new(timeout: options[:timeout])
      checker = Checker.new(runner: runner)
      names = command == 'grafana-alerts' ? %i[grafana_alerts alertmanager] : [CHECKS.fetch(command)]
      results = names.map do |name|
        begin
          case name
          when :edge_smoke then checker.edge_smoke(options)
          when :log_noise then checker.log_noise(options[:period], options[:top])
          else checker.public_send(name)
          end
        rescue StandardError => e
          label = { gitops: 'gitops', cnpg_clusters: 'cnpg-clusters' }.fetch(name, name.to_s.tr('_', '-'))
          checker.failed(label, e)
        end
      end
      if options[:format] == 'ndjson'
        results.each { |r| stdout.puts JSON.generate(r) }
      else
        stdout.puts "Collected at #{Time.now.utc.iso8601}\n\n"
        results.each do |r|
          stdout.puts "[#{r[:status].upcase}] #{r[:name]}: #{r[:summary]}"
          r[:details].each { |d| stdout.puts "  - #{d}" } if r[:status] == 'fail' || options[:verbose] || options[:raw]
          stdout.puts
        end
      end
      failed = results.any? { |r| r[:status] == 'fail' }
      if options[:notify] && failed
        message = results.select { |r| r[:status] == 'fail' }.map { |r| "#{r[:name]}: #{r[:summary]}" }.join('; ')
        output = runner.run('scripts/notify', '--status', 'failure', '--title', 'Cluster health: action needed', '--message', message)
        stderr.puts "send notification: #{checker.output_message(output, 'notification failed')}" unless output.exit_code.zero?
      end
      failed ? 1 : 0
    rescue OptionParser::ParseError => e
      stderr.puts e.message
      2
    end
  end
end

exit HomeOps::ClusterHealth.run_cli(ARGV) if $PROGRAM_NAME == __FILE__
