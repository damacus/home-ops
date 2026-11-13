# frozen_string_literal: true

module HomeOps
  module Provisioning
    module Build
      def build_plan
        version = current_k3s_version
        base = [ENV['PROVISIONING_K3S_RELEASE_BASE_URL'], ENV['K3S_RELEASE_BASE_URL'], 'https://github.com/k3s-io/k3s/releases/download'].find { |value| !value.to_s.empty? }
        base = "#{base.sub(%r{/+\z}, '')}/#{URI.encode_www_form_component(version)}"
        { 'k3s' => { 'version' => version, 'binary_url' => "#{base}/k3s-arm64",
                     'airgap_url' => "#{base}/k3s-airgap-images-arm64.tar", 'checksum_url' => "#{base}/sha256sum-arm64.txt" },
          'home_ops_commit' => repo_commit, 'armbian_commit' => armbian_commit,
          'build_parameters' => App::PARAMETERS.dup }
      end

      def run_build(args)
        catch(:help) do
          flags = options(args, 'provisioning build [--dry-run] [--verbose]', booleans: %w[dry-run verbose])
          positionals(args, 0, 'provisioning build [--dry-run] [--verbose]')
          plan = build_plan
          return json(plan) if flags['dry-run']
          raise Error, 'required program is unavailable: docker' unless available?('docker')
          require_build_inputs_unchanged(plan)
          staged = stage_k3s_payloads(plan)
          previous = output_snapshot
          with_injected_userpatches(staged) do
            argv = ['build', *App::PARAMETERS.map { |key, value| "#{key}=#{value}" }]
            argv << 'PROGRESS_DISPLAY=plain' if flags['verbose']
            run('./compile.sh', *argv, dir: armbian, stderr: true)
          end
          require_build_inputs_unchanged(plan)
          candidates = output_snapshot.select { |path, state| !previous.key?(path) || state[0] > previous[path][0] || state[1] != previous[path][1] }
          candidate = candidates.max_by { |_path, state| state[0] }&.first
          raise Error, 'Armbian build produced no new .img.xz image' unless candidate
          puts write_artifact_candidate(plan, staged, candidate, Time.now.utc)
        end
      end

      def output_snapshot
        Dir.glob(File.join(armbian, 'output/images/*.img.xz')).to_h { |path| [path, [File.mtime(path), File.size(path)]] }
      end

      def require_clean_build_sources
        relevant = ['.mise/tasks/provisioning', 'scripts/provisioning.rb', 'lib/home_ops/provisioning',
                    'mise.toml', 'mise.lock', 'provisioning', 'kubernetes/apps/system-upgrade/k3s/app/plan.yaml',
                    ':(exclude)provisioning/armbian-build/.staging']
        dirty = capture('git', 'status', '--porcelain', '--untracked-files=all', '--', *relevant)
        raise Error, "build inputs are dirty; commit or remove these changes first:\n#{dirty}" unless dirty.empty?
      end

      def require_clean_armbian(expected, allow_userpatches: false)
        raise Error, "Armbian submodule is not initialised; run git submodule update --init -- #{armbian}" unless exists?(File.join(armbian, '.git'))
        actual = capture('git', 'rev-parse', 'HEAD', dir: armbian)
        raise Error, "Armbian submodule is at #{actual}, expected #{expected}" unless actual == expected
        argv = %w[status --porcelain --untracked-files=all --ignored -- .] + %w[:(exclude)cache :(exclude)output :(exclude).tmp]
        argv << ':(exclude)userpatches' if allow_userpatches
        dirty = capture('git', *argv, dir: armbian).lines.map(&:chomp).reject { |line| ['', '!! Dockerfile', '!! .dockerignore'].include?(line) }
        raise Error, "pinned Armbian checkout is dirty:\n#{dirty.join("\n")}" unless dirty.empty?
      end

      def require_armbian_command(command, handler)
        contents = File.read(File.join(armbian, 'lib/functions/cli/commands.sh'))
        pattern = /^\s*\["#{Regexp.escape(command)}"\]\s*=\s*"#{Regexp.escape(handler)}"(\s|#|$)/
        raise Error, "pinned Armbian source does not register compile.sh #{command}" unless pattern.match?(contents)
      end

      def require_build_inputs_unchanged(plan)
        actual = repo_commit
        raise Error, "home-ops HEAD changed during build: expected #{plan['home_ops_commit']}, found #{actual}" unless actual == plan['home_ops_commit']
        require_clean_build_sources
        require_clean_armbian(plan['armbian_commit'], allow_userpatches: true)
        require_armbian_command('build', 'standard_build')
        unless File.read(File.join(armbian, 'lib/functions/image/partitioning.sh')).include?('FIXED_IMAGE_SIZE')
          raise Error, 'pinned Armbian source does not support FIXED_IMAGE_SIZE'
        end
      end

      def run_armbian(args)
        positionals(args, 2, 'provisioning armbian check docker-purge')
        raise UsageError, 'usage: provisioning armbian check docker-purge' unless args == %w[check docker-purge]
        require_clean_armbian(armbian_commit)
        require_armbian_command('docker-purge', 'docker')
      end

      def stage_k3s_payloads(plan)
        directory = File.join(image_root, '.staging')
        FileUtils.mkdir_p(directory)
        paths = { 'binary' => File.join(directory, 'k3s-arm64'), 'airgap' => File.join(directory, 'k3s-airgap-images-arm64.tar'),
                  'checksum' => File.join(directory, 'sha256sum-arm64.txt') }
        paths.each do |key, path|
          begin
            run('curl', '--fail', '--location', '--max-time', '120', '--output', "#{path}.tmp", plan.fetch('k3s').fetch("#{key}_url"), stderr: true)
            File.chmod(0o600, "#{path}.tmp")
            File.rename("#{path}.tmp", path)
          ensure
            FileUtils.rm_f("#{path}.tmp")
          end
        end
        checksums = File.readlines(paths['checksum']).filter_map do |line|
          match = /\A([0-9a-fA-F]{64})\s+\*?(\S+)\s*\z/.match(line)
          [File.basename(match[2]), match[1].downcase] if match
        end.to_h
        %w[binary airgap].each do |key|
          path = paths[key]
          expected = checksums[File.basename(path)]
          raise Error, "release checksum list does not contain #{File.basename(path)}" unless expected
          actual = Digest::SHA256.file(path).hexdigest
          raise Error, "checksum mismatch for #{File.basename(path)}: expected #{expected}, got #{actual}" unless expected == actual
        end
        paths
      end

      def with_injected_userpatches(staged)
        destination = File.join(armbian, 'userpatches')
        backup_root = Dir.mktmpdir('.userpatches-backup-', armbian)
        backup = File.join(backup_root, 'userpatches')
        had_existing = exists?(destination)
        File.rename(destination, backup) if had_existing
        begin
          FileUtils.cp_r(File.join(image_root, 'userpatches'), destination, preserve: true)
          copy_file(staged['binary'], File.join(destination, 'overlay/usr/local/bin/k3s'), 0o755)
          copy_file(staged['airgap'], File.join(destination, 'overlay/var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar'), 0o644)
          yield
        ensure
          FileUtils.rm_rf(destination)
          File.rename(backup, destination) if had_existing
          FileUtils.remove_entry(backup_root)
        end
      end

      def copy_file(source, destination, mode)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.copy_file(source, destination)
        File.chmod(mode, destination)
      end

      def write_artifact_candidate(plan, staged, candidate, timestamp)
        release_id = "radxa-5b-plus-#{timestamp.strftime('%Y%m%d')}-#{plan.fetch('home_ops_commit')[0, 12]}"
        set = artifact_paths(p('provisioning/artifacts', "#{release_id}.img.xz"))
        set.each_value { |path| raise Error, "artifact set member already exists: #{path}" if exists?(path) }
        FileUtils.mkdir_p(File.dirname(set['image']))
        File.rename(candidate, set['image'])
        complete = false
        begin
          image_hash = Digest::SHA256.file(set['image']).hexdigest
          File.write(set['checksum'], "#{image_hash}  #{File.basename(set['image'])}\n", mode: 'w', perm: 0o644)
          files = set.to_h { |key, path| [key, { 'filename' => File.basename(path) }] }
          files['image']['sha256'] = image_hash
          files['k3s_binary'] = { 'filename' => 'k3s-arm64', 'sha256' => Digest::SHA256.file(staged['binary']).hexdigest }
          files['k3s_airgap'] = { 'filename' => 'k3s-airgap-images-arm64.tar', 'sha256' => Digest::SHA256.file(staged['airgap']).hexdigest }
          manifest = { 'schema_version' => 1, 'release_id' => release_id, 'timestamp' => timestamp.iso8601,
                       'home_ops_commit' => plan['home_ops_commit'], 'k3s_version' => plan.dig('k3s', 'version'),
                       'armbian_commit' => plan['armbian_commit'], 'board' => App::PARAMETERS['BOARD'],
                       'branch' => App::PARAMETERS['BRANCH'], 'release' => App::PARAMETERS['RELEASE'],
                       'build_parameters' => App::PARAMETERS, 'files' => files }
          File.write(set['manifest'], JSON.pretty_generate(manifest) + "\n", mode: 'w', perm: 0o644)
          complete = true
          set['image']
        ensure
          set.each_value { |path| FileUtils.rm_f(path) } unless complete
        end
      end
    end
  end
end
