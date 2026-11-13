# frozen_string_literal: true

require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "optparse"
require "tmpdir"
require "zlib"

module HomeOps
  module Provisioning
    # Checks the image itself; no command below writes to an inspected rootfs.
    module Verification
      def run_verify(args)
        options = {}
        parser = OptionParser.new do |o|
          o.banner = "usage: provisioning verify [<artifact>] [--rootfs <directory>] [--raw]"
          o.on("--rootfs PATH") { |v| options[:rootfs] = v }
          o.on("--manifest PATH") { |v| options[:manifest] = v }
          o.on("--k3s-version VERSION") { |v| options[:version] = v }
          o.on("--raw") { options[:raw] = true }
          o.on("-h", "--help") { options[:help] = true }
        end
        parser.parse!(args)
        return puts(parser) if options[:help]
        raise UsageError, parser.banner if args.length > 1 || (options[:rootfs] && !args.empty?)
        raise UsageError, "verify requires an artifact or --rootfs" if !options[:rootfs] && args.empty?

        report = if options[:rootfs]
          manifest = JSON.parse(File.read(options[:manifest])) if options[:manifest]
          verify_rootfs(options[:rootfs], manifest, options[:version].to_s)
        else
          set, manifest = validate_artifacts(args.fetch(0))
          inspect_image_rootfs(set.fetch("image"), manifest)
        end
        if options[:raw]
          json(report)
        else
          report.fetch("checks").sort.each do |name, check|
            puts "#{check.fetch('status').upcase} #{name}: #{check.fetch('detail')}"
          end
        end
        raise Error, "image verification failed" unless report.fetch("status") == "pass"
      end

      def verify_rootfs(rootfs, manifest = nil, reported_version = "")
        rootfs = File.expand_path(rootfs)
        raise Error, "rootfs input is not a directory: #{rootfs}" unless File.directory?(rootfs)
        root = ->(*parts) { File.join(rootfs, *parts) }
        checks = {}
        check = ->(name, ok, detail) { checks[name] = {"status" => ok ? "pass" : "fail", "detail" => detail} }
        check.call("rootfs_identity", File.file?(root.call("etc/os-release")), "rootfs contains an operating-system identity")
        keys_path = root.call("home/pi/.ssh/authorized_keys")
        keys = read_verification_files(keys_path).strip.split("\n")
        passwd = read_verification_files(root.call("etc/passwd"))
        check.call("pi_access", passwd.match?(/^pi:[^:]*:1000:/) && keys == [self.class::PUBLIC_KEY], "pi user and approved key are present")
        key_mode = verification_mode(keys_path)
        ssh_mode = verification_mode(root.call("home/pi/.ssh"))
        check.call("authorized_keys_mode", key_mode == 0o600 && ssh_mode == 0o700, format("authorized_keys=%#o, .ssh=%#o", key_mode, ssh_mode))
        home_mode = verification_mode(root.call("home/pi"))
        check.call("pi_home", home_mode == 0o750, home_mode == 0o750 ? "pi home has mode 0750" : format("pi home mode=%#o, want 0750", home_mode))
        begin
          values = %w[PasswordAuthentication KbdInteractiveAuthentication PermitRootLogin].map { |key| effective_sshd_value(rootfs, key) }
          detail = %w[PasswordAuthentication KbdInteractiveAuthentication PermitRootLogin].zip(values).map { |key, value| "#{key}=#{value}" }.join(", ")
          check.call("ssh_policy", values == %w[no no no], detail)
        rescue StandardError => e
          check.call("ssh_policy", false, "invalid SSH include: #{e.message}")
        end
        check.call("unattended_upgrades", unattended_upgrade_policy?(rootfs) && valid_timer_activation?(rootfs), "all Noble and Armbian origins enabled; timer active")
        begin
          state = unexpected_cluster_state(rootfs)
          check.call("cluster_state", state.empty?, state.empty? ? "only immutable K3s payload inputs are baked" : "unexpected cluster state: #{state.join(', ')}")
        rescue StandardError => e
          check.call("cluster_state", false, "inspect cluster state: #{e.message}")
        end
        kube_mode = verification_mode(root.call("etc/rancher/k3s/k3s.yaml"))
        check.call("kubeconfig_mode", [0, 0o600].include?(kube_mode), format("mode=%#o", kube_mode))
        machine_id = root.call("etc/machine-id")
        identity_clean = File.file?(machine_id) && File.size(machine_id).zero? &&
          !verification_exists?(root.call("var/lib/cloud/instance")) &&
          !verification_exists?(root.call("var/lib/cloud/instances")) &&
          Dir.glob(root.call("etc/ssh/ssh_host_*_key")).empty?
        check.call("clean_identity", identity_clean, "machine ID, cloud-init state, and SSH host keys are clean")
        shadow = read_verification_files(root.call("etc/shadow"))
        check.call("locked_accounts", shadow.match?(/^root:[!*]/) && shadow.match?(/^pi:[!*]/), "root and pi passwords are locked")
        packages = %w[cloud-init conntrack iptables ipvsadm multipath-tools nfs-common nvme-cli open-iscsi unattended-upgrades]
        missing = missing_verification_packages(read_verification_files(root.call("var/lib/dpkg/status")), packages)
        check.call("node_packages", missing.empty?, "missing=#{missing.empty? ? 'none' : missing.join(',')}")
        modules = read_verification_files(root.call("etc/modules-load.d/k3s.conf"))
        sysctls = read_verification_files(root.call("etc/sysctl.d/99-k3s.conf"))
        check.call("node_configuration", modules.include?("overlay") && modules.include?("br_netfilter") && sysctls.match?(/^net\.ipv4\.ip_forward\s*=\s*1/), "Kubernetes modules and forwarding sysctls are configured")
        inputs = %w[etc/cloud/cloud.cfg.d/99-ironstone.cfg var/lib/cloud/seed/nocloud/user-data etc/fstab].map { |path| root.call(path) }
        check.call("compact_rootfs", inputs.all? { |path| File.file?(path) } && !read_verification_files(*inputs).include?("K3S_DATA"), "required image inputs exist without a fixed K3S_DATA partition")
        service = root.call("etc/systemd/system/k3s.service")
        service_text = read_verification_files(service)
        dormant = File.file?(service) && service_text.include?("ConditionPathExists=/etc/rancher/k3s/config.yaml") &&
          service_text.include?("ConditionPathExists=/etc/rancher/k3s/cluster-token") &&
          Dir.glob(root.call("etc/systemd/system/*.wants/k3s.service")).empty? &&
          !read_verification_files(*Dir.glob(root.call("etc/systemd/system-preset/*.preset"))).match?(/^\s*enable\s+k3s\.service/)
        check.call("dormant_k3s", dormant, "K3s unit requires enrolment files and is disabled")
        embedded, detail = initramfs_includes_hook(rootfs)
        check.call("nvme_rescan", (verification_mode(root.call("etc/initramfs-tools/scripts/local-premount/nvme-rescan")) & 0o111) != 0 && embedded, "executable NVMe hook is embedded in #{detail}")
        if manifest
          binary = root.call("usr/local/bin/k3s")
          airgap = root.call("var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar")
          files = manifest.fetch("files", {})
          payload_ok = File.file?(binary) && File.file?(airgap) && verification_hash_matches?(binary, files.dig("k3s_binary", "sha256")) && verification_hash_matches?(airgap, files.dig("k3s_airgap", "sha256"))
          check.call("k3s_payloads", payload_ok, "matching K3s #{manifest['k3s_version']} payloads")
          versions = reported_version.scan(/\bv\d+\.\d+\.\d+\+k3s\d+\b/)
          check.call("k3s_version", versions.length == 1 && versions.first == manifest["k3s_version"], "binary reports #{reported_version.strip}")
        end
        {"status" => checks.values.all? { |entry| entry["status"] == "pass" } ? "pass" : "fail", "checks" => checks}
      end

      def effective_sshd_value(rootfs, key)
        canonical_root = File.realpath(rootfs)
        value = ""
        visiting = []
        parse = lambda do |path|
          return unless value.empty?
          resolved = File.realpath(path)
          raise Error, "configuration escapes rootfs: #{path}" unless inside_verification_root?(canonical_root, resolved)
          raise Error, "recursive SSH include: #{path}" if visiting.include?(resolved)
          visiting << resolved
          in_match = false
          File.foreach(resolved) do |line|
            fields = line.split("#", 2).first.to_s.strip.split
            next if fields.empty?
            if fields.first.casecmp?("Match")
              in_match = true
            elsif fields.first.casecmp?("Include") && !in_match
              fields.drop(1).each do |pattern|
                candidate = if pattern.start_with?("/")
                  File.expand_path(pattern.delete_prefix("/"), canonical_root)
                else
                  File.expand_path(pattern, File.join(canonical_root, "etc/ssh"))
                end
                raise Error, "include escapes rootfs: #{pattern}" unless inside_verification_root?(canonical_root, candidate)
                Dir.glob(candidate).sort.each do |match|
                  raise Error, "include escapes rootfs: #{pattern}" unless inside_verification_root?(canonical_root, File.realpath(match))
                  parse.call(match)
                end
              end
            elsif !in_match && fields.length > 1 && fields.first.casecmp?(key)
              value = fields[1].downcase
              break
            end
          end
          visiting.pop
        end
        parse.call(File.join(canonical_root, "etc/ssh/sshd_config"))
        value
      end

      def inside_verification_root?(root, path)
        candidate = File.expand_path(path)
        candidate == root || candidate.start_with?(root + File::SEPARATOR)
      end

      def valid_timer_activation?(rootfs)
        activation = File.join(rootfs, "etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer")
        target = File.readlink(activation)
        resolved = if target.start_with?("/")
          File.expand_path(target.delete_prefix("/"), rootfs)
        else
          File.expand_path(target, File.dirname(activation))
        end
        %w[lib/systemd/system/apt-daily-upgrade.timer usr/lib/systemd/system/apt-daily-upgrade.timer].any? do |path|
          resolved == File.join(rootfs, path) && File.file?(resolved)
        end
      rescue SystemCallError
        false
      end

      def unattended_upgrade_policy?(rootfs)
        paths = [File.join(rootfs, "etc/apt/apt.conf")] + Dir.glob(File.join(rootfs, "etc/apt/apt.conf.d/*")).sort
        configuration = paths.select { |path| File.file?(path) }.map do |path|
          File.read(path).gsub(%r{/\*.*?\*/}m, "").lines.map { |line| line.split(%r{//|#}, 2).first.to_s }.join("\n")
        end.join("\n")
        setting = ->(name) { configuration.scan(/^\s*#{Regexp.escape(name)}\s+"?([^";\s]+)"?\s*;/).last.to_a.first.to_s.downcase }
        block_values = lambda do |name|
          configuration.scan(/#{Regexp.escape(name)}\s*\{(.*?)\};/m).flat_map { |block| block.first.scan(/"([^"]+)"\s*;/).flatten }
        end
        origins = block_values.call("Unattended-Upgrade::Allowed-Origins")
        required = %w[Ubuntu:noble Ubuntu:noble-updates Ubuntu:noble-security Ubuntu:noble-backports Armbian:noble]
        setting.call("APT::Periodic::Unattended-Upgrade") == "1" &&
          setting.call("Unattended-Upgrade::Automatic-Reboot") == "false" &&
          (required - origins).empty? &&
          block_values.call("Unattended-Upgrade::Package-Blacklist").none? { |value| value.match?(/linux-image|linux-dtb|linux-u-boot|armbian-firmware/i) }
      rescue SystemCallError
        false
      end

      def unexpected_cluster_state(rootfs)
        roots = %w[etc/rancher/k3s var/lib/rancher/k3s var/lib/kubelet var/lib/cni etc/cni/net.d etc/rancher/node]
        allowed = %w[etc/rancher/k3s/registries.yaml var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar]
        unexpected = []
        roots.each do |relative|
          state_root = File.join(rootfs, relative)
          next unless verification_exists?(state_root)
          Find.find(state_root) do |path|
            next if File.lstat(path).directory?
            name = path.delete_prefix(rootfs + "/")
            unexpected << name unless allowed.include?(name)
          end
        end
        unexpected.sort
      end

      def initramfs_includes_hook(rootfs)
        Dir.glob(File.join(rootfs, "boot/initrd.img-*")).sort.each do |image|
          begin
            return [true, File.basename(image)] if verification_archive_contains?(image, "scripts/local-premount/nvme-rescan")
          rescue StandardError
            # Compressed or concatenated formats are delegated to lsinitramfs.
          end
          output, status = Open3.capture2("lsinitramfs", image, err: File::NULL)
          return [true, File.basename(image)] if status.success? && output.include?("scripts/local-premount/nvme-rescan")
        rescue Errno::ENOENT
          next
        end
        [false, "a generated initramfs"]
      end

      def verification_archive_contains?(path, wanted)
        File.open(path, "rb") do |file|
          header = file.read(2)
          file.rewind
          reader = header == "\x1f\x8b".b ? Zlib::GzipReader.new(file) : file
          begin
            loop do
              header = verification_read_exact(reader, 110)
              raise Error, "not a newc archive" unless %w[070701 070702].include?(header[0, 6])
              name_size = Integer(header[94, 8], 16)
              file_size = Integer(header[54, 8], 16)
              raise Error, "invalid newc name size" if name_size < 1
              name = verification_read_exact(reader, name_size).delete_suffix("\0")
              verification_read_exact(reader, (4 - ((110 + name_size) % 4)) % 4)
              return false if name == "TRAILER!!!"
              return true if name == wanted
              remaining = file_size
              while remaining.positive?
                length = [remaining, 64 * 1024].min
                verification_read_exact(reader, length)
                remaining -= length
              end
              verification_read_exact(reader, (4 - (file_size % 4)) % 4)
            end
          ensure
            reader.close if reader != file
          end
        end
      end

      def verification_read_exact(reader, length)
        value = reader.read(length)
        raise EOFError, "truncated newc archive" unless value && value.bytesize == length
        value
      end

      def verification_mode(path)
        File.stat(path).mode & 0o777
      rescue SystemCallError
        0
      end

      def verification_exists?(path)
        File.lstat(path)
        true
      rescue SystemCallError
        false
      end

      def read_verification_files(*paths)
        paths.filter_map { |path| File.read(path) rescue nil }.join("\n")
      end

      def missing_verification_packages(status, wanted)
        installed = status.split("\n\n").filter_map do |paragraph|
          paragraph[/^Package:\s*(\S+)\s*$/, 1] if paragraph.match?(/^Status:\s+install ok installed\s*$/)
        end
        (wanted - installed).sort
      end

      def verification_hash_matches?(path, expected)
        expected.to_s.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(path).hexdigest == expected
      rescue SystemCallError
        false
      end

      def inspect_image_rootfs(image, manifest)
        image_size = xz_uncompressed_size(image)
        free = available_bytes(Dir.tmpdir)
        required = image_size + 1024**3
        raise Error, format("image extraction requires %.1f GiB; %.1f GiB is free", required.fdiv(1024**3), free.fdiv(1024**3)) if free < required
        Dir.mktmpdir("provisioning-verify-") do |temporary|
          raw = File.join(temporary, "image.img")
          File.open(raw, "wb", 0o600) do |file|
            pid = Process.spawn("xz", "-dc", image, out: file, err: $stderr)
            _, status = Process.wait2(pid)
            raise Error, "xz extraction failed" unless status.success?
            file.fsync
          end
          manifest_path = File.join(temporary, "manifest.json")
          File.write(manifest_path, JSON.generate(manifest), mode: "w", perm: 0o600)
          script = <<~'SH'
            set -eux
            apt-get update -qq >/dev/null
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq util-linux e2fsprogs initramfs-tools-core >/dev/null
            if command -v python3 >/dev/null 2>&1; then
              echo "verification container must not include Python" >&2
              exit 1
            fi
            loop=""
            mounted=false
            cleanup() {
              if [ "$mounted" = true ]; then umount /mnt/root 2>/dev/null || true; fi
              if [ -n "$loop" ]; then losetup -d "$loop" 2>/dev/null || true; fi
            }
            trap cleanup EXIT HUP INT TERM
            loop=$(losetup --find --show --partscan /image.img)
            lsblk -rno PATH,TYPE,MAJ:MIN "$loop" | while read -r candidate type device_number; do
              if [ "$type" = part ] && [ ! -b "$candidate" ]; then
                mknod -m 0660 "$candidate" b "${device_number%:*}" "${device_number#*:}"
              fi
            done
            mkdir -p /mnt/root
            root=""
            for candidate in $(lsblk -rno PATH,TYPE "$loop" | awk '$2 == "part" {print $1}'); do
              [ "$(blkid -s TYPE -o value "$candidate" || true)" = ext4 ] || continue
              mount -o ro,noload "$candidate" /mnt/root
              mounted=true
              if test -f /mnt/root/etc/os-release && test -x /mnt/root/usr/local/bin/k3s && test -f /mnt/root/var/lib/rancher/k3s/agent/images/k3s-airgap-images-arm64.tar; then
                root="$candidate"
                break
              fi
              umount /mnt/root
              mounted=false
            done
            test -n "$root"
            reported_version=$(chroot /mnt/root /usr/local/bin/k3s --version 2>&1)
            ruby /verifier/scripts/provisioning.rb verify --rootfs /mnt/root --manifest /verifier/manifest.json --k3s-version "$reported_version" --raw
          SH
          output = capture("docker", "run", "--rm", "--privileged", "--platform", "linux/arm64", "-e", "MISE_PROJECT_ROOT=/verifier",
            "-v", "#{raw}:/image.img:ro", "-v", "#{manifest_path}:/verifier/manifest.json:ro",
            "-v", "#{p('scripts/provisioning.rb')}:/verifier/scripts/provisioning.rb:ro",
            "-v", "#{p('lib/home_ops/provisioning')}:/verifier/lib/home_ops/provisioning:ro",
            "ruby:4.0.9-slim@sha256:d8cb2c0714bdaba0f318af897a01d2dbde3cfa8e62d47e99cea55feb13c0e90d", "sh", "-ceu", script)
          JSON.parse(output)
        end
      end

      def xz_uncompressed_size(image)
        capture("xz", "--robot", "--list", image).each_line do |line|
          fields = line.strip.split("\t")
          next unless fields.length >= 5 && fields.first == "totals"
          size = Integer(fields[4], 10)
          return size if size.positive?
        end
        raise Error, "could not determine the uncompressed image size"
      end

      def available_bytes(directory)
        lines = capture("df", "-Pk", directory).lines
        raise Error, "could not determine free disk space" if lines.length < 2
        Integer(lines.last.split.fetch(3), 10) * 1024
      rescue ArgumentError, IndexError
        raise Error, "could not determine free disk space"
      end
    end
  end
end
