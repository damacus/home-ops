# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'fileutils'
require 'digest'
require 'time'
require 'tmpdir'
require 'uri'
require 'shellwords'
require 'ipaddr'
require_relative 'build'
require_relative 'artifact'
require_relative 'flash'
require_relative 'lifecycle'
require_relative 'verify'

module HomeOps
  module Provisioning
    class Error < StandardError; end
    class UsageError < Error; end

    class App
      include Build
      include Artifact
      include Flash
      include Lifecycle
      include Verification

      PUBLIC_KEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMCLr7NoB34qERAAJNLHKgOy9EJ40smz4F9HhU5d5i8s'
      PARAMETERS = { 'BOARD' => 'rock-5b-plus', 'BRANCH' => 'vendor', 'RELEASE' => 'noble',
                     'BUILD_MINIMAL' => 'yes', 'BUILD_DESKTOP' => 'no', 'KERNEL_CONFIGURE' => 'no',
                     'INSTALL_HEADERS' => 'yes', 'INCLUDE_HOME_DIR' => 'yes',
                     'ENABLE_EXTENSIONS' => 'nvme-rescan', 'COMPRESS_OUTPUTIMAGE' => 'xz',
                     'FIXED_IMAGE_SIZE' => '3072' }.freeze

      def self.cli(args)
        new(ENV.fetch('MISE_PROJECT_ROOT', File.expand_path('../../..', __dir__))).dispatch(args.dup)
        0
      rescue UsageError, OptionParser::ParseError => e
        warn "error: #{e.message}"
        2
      rescue Error, SystemCallError, JSON::ParserError, ArgumentError, KeyError, TypeError => e
        warn "error: #{e.message}"
        1
      end

      def initialize(root)
        @root = File.expand_path(root)
      end

      def dispatch(args)
        command = args.shift
        if %w[-h --help help].include?(command)
          puts 'usage: provisioning <build|artifact|armbian|verify|flash|enrol|retire> [arguments]'
          return
        end
        raise UsageError, 'usage: provisioning <command> [arguments]' unless command
        raise UsageError, "unknown command #{command.inspect}" unless %w[build artifact armbian verify flash enrol retire].include?(command)
        public_send("run_#{command}", args)
      end

      def p(*parts) = File.join(@root, *parts)
      def image_root = p('provisioning/armbian-build')
      def armbian = File.join(image_root, 'armbian-build-repo')
      def k3s_plan_path = p('kubernetes/apps/system-upgrade/k3s/app/plan.yaml')
      def exists?(path) = File.exist?(path) || File.symlink?(path)
      def json(value) = puts(JSON.pretty_generate(value))

      def options(args, usage, booleans: [], values: [])
        result = {}
        parser = OptionParser.new { |o| o.banner = "usage: #{usage}" }
        booleans.each { |flag| parser.on("--#{flag}") { result[flag] = true } }
        values.each { |flag| parser.on("--#{flag} VALUE") { |value| result[flag] = value } }
        parser.on('-v') { result['verbose'] = true } if booleans.include?('verbose')
        parser.on('-h', '--help') { puts parser; throw :help }
        parser.parse!(args)
        result
      end

      def positionals(args, count, usage)
        raise UsageError, "usage: #{usage}" unless args.length == count
      end

      def capture(*argv, input: nil, dir: @root)
        stdout, stderr, status = Open3.capture3(*argv, stdin_data: input.to_s, chdir: dir)
        raise Error, "#{argv.first} failed: #{[stderr.strip, stdout.strip].reject(&:empty?).join("\n")}" unless status.success?
        stdout.strip
      rescue SystemCallError, IOError => e
        raise Error, "#{argv.first} failed: #{e.message}"
      end

      def run(*argv, input: nil, dir: @root, stderr: false, secret: false)
        if secret
          _out, _err, status = Open3.capture3(*argv, stdin_data: input.to_s, chdir: dir)
          raise Error, "#{argv.first} failed while transferring secret" unless status.success?
          return
        end
        if input
          Open3.popen3(*argv, chdir: dir) do |stdin, stdout, error, wait|
            writers = [Thread.new { IO.copy_stream(stdout, stderr ? $stderr : $stdout) }, Thread.new { IO.copy_stream(error, $stderr) }]
            begin
              stdin.write(input)
            ensure
              stdin.close
            end
            writers.each(&:join)
            raise Error, "#{argv.first} failed" unless wait.value.success?
          end
        else
          success = system(*argv, chdir: dir, out: stderr ? $stderr : $stdout, err: $stderr)
          raise Error, "#{argv.first} failed" unless success
        end
      rescue SystemCallError, IOError => e
        raise Error, secret ? "#{argv.first} failed while transferring secret" : "#{argv.first} failed: #{e.message}"
      end

      def available?(name)
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |path| File.executable?(File.join(path, name)) }
      end

      def current_k3s_version
        versions = File.read(k3s_plan_path).scan(/^\s*version:\s*(v\d+\.\d+\.\d+\+k3s\d+)\s*$/).flatten
        raise Error, "expected two K3s Plan versions, found #{versions.length}" unless versions.length == 2
        raise Error, "K3s Plan versions differ: #{versions.join(', ')}" unless versions.uniq.length == 1
        versions.first
      end

      def repo_commit
        commit = capture('git', 'rev-parse', 'HEAD')
        raise Error, 'repository HEAD is not a full commit' unless /\A[0-9a-f]{40}\z/.match?(commit)
        commit
      end

      def armbian_commit
        output = capture('git', 'ls-files', '--stage', '--', 'provisioning/armbian-build/armbian-build-repo')
        match = /\A160000 ([0-9a-f]{40}) 0\t.+\z/.match(output)
        raise Error, "#{armbian} is not a pinned git submodule" unless match
        match[1]
      end

      def confirmation(expected, action)
        $stderr.print "Type #{expected} #{action}: "
        raise Error, 'confirmation did not match' unless $stdin.gets.to_s.strip == expected
      end
    end
  end
end
