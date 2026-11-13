# frozen_string_literal: true

module HomeOps
  module Provisioning
    module Lifecycle
      TOKEN_PATH = '/etc/rancher/k3s/cluster-token'
      STAGE_PATH = '/etc/rancher/k3s/.enrol-staging'
      RETIRED_PATHS = %w[/etc/rancher/k3s /var/lib/rancher/k3s /var/lib/kubelet /var/lib/cni /etc/cni/net.d /etc/rancher/node].freeze

      def run_enrol(args)
        catch(:help) do
          flags = options(args, 'provisioning enrol <host> [--source-node NODE] [--node-ip IPv4] [--replace] [--dry-run]',
                          booleans: %w[replace dry-run], values: %w[source-node node-ip ready-timeout])
          positionals(args, 1, 'provisioning enrol <host> [--source-node NODE] [--node-ip IPv4] [--replace] [--dry-run]')
          raise UsageError, '--node-ip must be an IPv4 address' if flags.key?('node-ip') && !ipv4?(flags['node-ip'])
          ready_timeout = flags.key?('ready-timeout') ? duration(flags['ready-timeout']) : 300
          host = args.first
          begin
            capture('kubectl', 'get', '--raw=/readyz')
          rescue Error => e
            raise Error, "Kubernetes API is not healthy: #{e.message}"
          end
          source = control_plane_source(flags['source-node'].to_s)
          source_host = node_address(source)
          name = ssh_output(host, 'hostname -s')
          raise Error, "target hostname does not match the baked node identity contract: #{name.inspect}" unless /\Anode-[a-f0-9]{6}\z/.match?(name)
          existing = existing_node(name)
          if existing
            raise Error, "refusing to replace Ready Kubernetes node #{name}" if node_ready?(existing)
            raise Error, "Kubernetes node #{name} already exists; pass --replace explicitly" unless flags['replace']
          end
          enrol_target_preflight(host)
          version = current_k3s_version
          raise Error, "target K3s version does not match #{version}" unless ssh_output(host, 'sudo /usr/local/bin/k3s --version').include?(version)
          endpoint = current_api_endpoint
          ip = resolve_node_ip(host, endpoint, flags['node-ip'])
          actions = ['install sanitised config mode 0600', 'install redacted server token mode 0600', 'enable and start k3s']
          plan = { 'source_node' => source.dig('metadata', 'name'), 'source_host' => source_host,
                   'target_host' => host, 'target_hostname' => name, 'node_ip' => ip, 'k3s_version' => version,
                   'replacement' => existing && node_state(existing), 'actions' => actions, 'token' => '<redacted>' }
          return json(plan) if flags['dry-run']
          confirmation("replace #{name}", 'to delete the NotReady node') if existing
          begin
            source_config = ssh_output(source_host, 'sudo cat /etc/rancher/k3s/config.yaml')
          rescue Error
            raise Error, 'could not read source K3s config'
          end
          config = sanitise_k3s_config(source_config, endpoint, ip)
          token = read_source_token(source_host)
          begin
            run('kubectl', 'delete', 'node', name, stderr: true) if existing
            stage_target_enrol_files(host, config, token)
            run('ssh', "pi@#{host}", 'sudo systemctl enable --now k3s.service', stderr: true)
            wait_for_enrolled_node(name, host, token, ready_timeout)
          rescue Error => e
            raise Error, redact_secret(e.message, token)
          end
          json('node' => name, 'host' => host, 'source_node' => source.dig('metadata', 'name'),
               'node_ip' => ip, 'actions' => actions, 'token' => '<redacted>')
        end
      end

      def read_source_token(host)
        begin
          token = ssh_output(host, 'sudo cat /var/lib/rancher/k3s/server/token')
        rescue Error
          raise Error, 'could not read source K3s token'
        end
        raise Error, 'source node returned an empty K3s token' if token.empty?
        token
      end

      def run_retire(args)
        catch(:help) do
          flags = options(args, 'provisioning retire <node> <host> [--dry-run]', booleans: %w[dry-run])
          positionals(args, 2, 'provisioning retire <node> <host> [--dry-run]')
          node, host = args
          actions = ['preflight target identity, sudo, and k3s', 'kubectl drain', 'disable and stop k3s', 'kubectl delete node', 'remove K3s config and state']
          return json('node' => node, 'host' => host, 'actions' => actions) if flags['dry-run']
          hostname = ssh_output(host, 'hostname -s')
          raise Error, "target hostname #{hostname.inspect} does not match node #{node.inspect}" unless hostname == node
          ssh_output(host, 'sudo -n true')
          ssh_output(host, 'systemctl cat k3s.service >/dev/null')
          confirmation(node, 'to retire it')
          existing = existing_node(node)
          run('kubectl', 'drain', node, '--ignore-daemonsets', '--delete-emptydir-data', stderr: true) if existing
          run('ssh', "pi@#{host}", 'sudo systemctl disable --now k3s.service', stderr: true)
          run('kubectl', 'delete', 'node', node, stderr: true) if existing
          run('ssh', "pi@#{host}", "sudo rm -rf #{RETIRED_PATHS.join(' ')}", stderr: true)
          json('node' => node, 'host' => host, 'actions' => actions)
        end
      end

      def enrol_target_preflight(host)
        ['sudo -n true', 'test -s /etc/machine-id'].each { |command| ssh_output(host, command) }
        cloud_init = ssh_output(host, 'cloud-init status --wait')
        raise Error, "target cloud-init has not completed: #{cloud_init}" unless cloud_init.include?('status: done')
        enabled = ssh_output(host, 'systemctl is-enabled k3s.service 2>/dev/null || true')
        active = ssh_output(host, 'systemctl is-active k3s.service 2>/dev/null || true')
        raise Error, "target K3s must be dormant before enrolment: enabled=#{enabled}, active=#{active}" unless enabled == 'disabled' && active == 'inactive'
        ssh_output(host, 'sudo test ! -e /etc/rancher/k3s/config.yaml -a ! -e /etc/rancher/k3s/cluster-token -a ! -e /var/lib/rancher/k3s/server/token -a ! -d /var/lib/rancher/k3s/server/db')
      end

      def control_plane_source(selected)
        nodes = JSON.parse(capture('kubectl', 'get', 'nodes', '-o', 'json')).fetch('items')
        source = nodes.find { |node| (selected.empty? || node.dig('metadata', 'name') == selected) && node_ready?(node) && node_control_plane?(node) }
        raise Error, selected.empty? ? 'no Ready control-plane source node is available' : "requested source node #{selected} is not a Ready control-plane" unless source
        source
      end

      def existing_node(name)
        output = capture('kubectl', 'get', 'node', name, '--ignore-not-found', '--request-timeout=10s', '-o', 'json')
        return nil if output.empty?
        node = JSON.parse(output)
        raise Error, "Kubernetes returned an unexpected node identity for #{name}" unless node.dig('metadata', 'name') == name
        node
      end

      def current_api_endpoint
        clusters = JSON.parse(capture('kubectl', 'config', 'view', '--minify', '-o', 'json')).fetch('clusters')
        raise Error, 'Kubernetes config does not contain one active API endpoint' unless clusters.length == 1 && !clusters.first.dig('cluster', 'server').to_s.empty?
        clusters.first.dig('cluster', 'server')
      end

      def resolve_node_ip(host, endpoint, override)
        parsed = URI.parse(endpoint)
        raise Error, "invalid Kubernetes API endpoint #{endpoint.inspect}" if parsed.hostname.to_s.empty?
        routes = JSON.parse(ssh_output(host, "ip -j route get #{Shellwords.escape(parsed.hostname)}"))
        raise Error, 'parse route to Kubernetes API endpoint' if routes.empty?
        route = routes.first
        device = route['dev'].to_s
        raise Error, 'route to Kubernetes API endpoint lacks a device' if device.empty?
        interfaces = JSON.parse(ssh_output(host, "ip -j addr show dev #{Shellwords.escape(device)}"))
        raise Error, "parse addresses for interface #{device}" if interfaces.empty?
        selected = override || route['prefsrc']
        raise Error, 'route to Kubernetes API endpoint lacks an IPv4 preferred source' unless ipv4?(selected)
        assigned = interfaces.any? { |interface| Array(interface['addr_info']).any? { |address| address['family'] == 'inet' && address['local'] == selected } }
        raise Error, "node IP #{selected} is not assigned to interface #{device}" unless assigned
        selected
      end

      def sanitise_k3s_config(source, endpoint, ip)
        filter = %Q{.server = #{endpoint.to_json} | ."token-file" = #{TOKEN_PATH.to_json} | ."node-ip" = #{ip.to_json} | ."kube-apiserver-arg" = ((."kube-apiserver-arg" // []) | map(select(test("^anonymous-auth(=true)?$") | not))) | del(."node-external-ip", ."node-name", ."node-label", ."node-taint", ."advertise-address", ."bind-address", ."flannel-iface", .token, ."write-kubeconfig-mode", ."cluster-init", ."cluster-reset", ."cluster-reset-restore-path")}
        begin
          config = capture('yq', 'eval', filter, '-', input: source)
        rescue Error
          raise Error, 'could not sanitise source K3s config'
        end
        if /anonymous-auth\s*(?:=|:)\s*true/i.match?(config) || /write-kubeconfig-mode\s*:\s*["']?0?644/i.match?(config)
          raise Error, 'source K3s config contains unsafe authentication or kubeconfig settings'
        end
        config + "\n"
      end

      def stage_target_enrol_files(host, config, token)
        run('ssh', "pi@#{host}", "sudo install -d -m 0700 #{STAGE_PATH} && sudo rm -f #{STAGE_PATH}/config.yaml #{STAGE_PATH}/cluster-token", stderr: true)
        begin
          run('ssh', "pi@#{host}", "sudo install -m 0600 /dev/stdin #{STAGE_PATH}/config.yaml", input: config, stderr: true)
          run('ssh', "pi@#{host}", "sudo install -m 0600 /dev/stdin #{STAGE_PATH}/cluster-token", input: token + "\n", secret: true)
          promote = "sudo sh -c 'if mv #{STAGE_PATH}/config.yaml /etc/rancher/k3s/config.yaml && mv #{STAGE_PATH}/cluster-token #{TOKEN_PATH} && rmdir #{STAGE_PATH}; then exit 0; fi; rm -f /etc/rancher/k3s/config.yaml #{TOKEN_PATH}; rm -rf #{STAGE_PATH}; exit 1'"
          run('ssh', "pi@#{host}", promote, stderr: true)
        rescue Error => operation_error
          begin
            run('ssh', "pi@#{host}", "sudo rm -rf #{STAGE_PATH}", stderr: true)
          rescue Error => cleanup_error
            raise Error, "#{operation_error.message}; clear enrolment staging: #{cleanup_error.message}"
          end
          raise operation_error
        end
      end

      def wait_for_enrolled_node(name, host, token, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        state = 'node not found'
        loop do
          begin
            node = existing_node(name)
            if node
              state = { 'ready' => node_ready?(node), 'control_plane' => node_control_plane?(node), 'etcd' => node_etcd?(node) }.to_json
              return if node_ready?(node) && node_control_plane?(node) && node_etcd?(node)
            end
          rescue Error => e
            state = redact_secret(e.message, token)
          end
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0
          sleep([5, remaining].min)
        end
        begin
          logs = ssh_output(host, "timeout 15s sudo -n journalctl -u k3s.service --no-pager -n 200 --since '-10 minutes'")
        rescue Error
          logs = '<unavailable>'
        end
        logs = redact_secret(logs, token)
        raise Error, "node #{name} did not become Ready with control-plane and etcd roles within #{timeout}s; last state: #{state}; recent k3s logs:\n#{logs[-8000, 8000] || logs}"
      end

      def ssh_output(host, command)
        capture('ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', "pi@#{host}", command)
      end

      def node_ready?(node) = Array(node.dig('status', 'conditions')).any? { |condition| condition['type'] == 'Ready' && condition['status'] == 'True' }
      def node_control_plane?(node) = %w[control-plane master].any? { |role| node.fetch('metadata').fetch('labels', {}).key?("node-role.kubernetes.io/#{role}") }
      def node_etcd?(node) = node.fetch('metadata').fetch('labels', {}).key?('node-role.kubernetes.io/etcd')
      def node_state(node) = { 'name' => node.dig('metadata', 'name'), 'uid' => node.dig('metadata', 'uid'), 'ready' => node_ready?(node), 'unschedulable' => node.dig('spec', 'unschedulable') || false }

      def node_address(node)
        %w[InternalIP ExternalIP Hostname].each do |kind|
          address = Array(node.dig('status', 'addresses')).find { |item| item['type'] == kind && !item['address'].to_s.empty? }
          return address['address'] if address
        end
        raise Error, "node #{node.dig('metadata', 'name')} has no SSH address"
      end

      def ipv4?(value)
        ip = IPAddr.new(value.to_s)
        ip.ipv4? && ip.to_s == value
      rescue IPAddr::Error
        false
      end

      def duration(value)
        value = value.delete_prefix('+')
        return 0 if value == '0'
        components = value.scan(/((?:\d+(?:\.\d*)?|\.\d+))(ns|us|µs|ms|s|m|h)/)
        raise UsageError, '--ready-timeout must be a non-negative duration' if components.empty? || components.map(&:join).join != value
        units = { 'ns' => 1e-9, 'us' => 1e-6, 'µs' => 1e-6, 'ms' => 0.001, 's' => 1, 'm' => 60, 'h' => 3600 }
        components.sum { |number, unit| number.to_f * units.fetch(unit) }
      end

      def redact_secret(value, secret) = secret.empty? ? value : value.gsub(secret, '<redacted>')
    end
  end
end
