# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'time'
require 'timeout'
require 'uri'

module HomeOps
  module ClusterHealth
    Output = Struct.new(:stdout, :stderr, :exit_code, keyword_init: true)

    class Runner
      def initialize(timeout: 45)
        @timeout = timeout
      end

      def run(*command)
        out = err = ''
        status = nil
        Open3.popen3(*command, pgroup: true) do |input, stdout, stderr, waiter|
          input.close
          readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
          begin
            Timeout.timeout(@timeout) { status = waiter.value }
          rescue Timeout::Error
            Process.kill('KILL', -waiter.pid) rescue Errno::ESRCH
            waiter.value
            status = 124
          ensure
            out, err = readers.map(&:value)
          end
        end
        if status == 124
          err = "command timed out after #{@timeout}s: #{command.join(' ')}"
          return Output.new(stdout: out, stderr: err, exit_code: 124)
        end
        Output.new(stdout: out, stderr: err, exit_code: status.exitstatus || 1)
      rescue SystemCallError => e
        Output.new(stdout: '', stderr: e.message, exit_code: 127)
      end
    end

    class Checker
      def initialize(runner: Runner.new, now: -> { Time.now.utc })
        @runner, @now = runner, now
      end

      def result(name, failures, pass, fail, details = failures)
        { name: name, status: failures.empty? ? 'pass' : 'fail',
          summary: failures.empty? ? pass : fail, details: details }
      end

      def failed(name, error)
        { name: name, status: 'fail', summary: "#{name} check failed", details: [error.to_s] }
      end

      def output_message(output, fallback)
        [output.stderr, output.stdout].map(&:strip).find { |s| !s.empty? } || fallback
      end

      def kubectl(*args)
        output = @runner.run('kubectl', *args, '-o', 'json')
        raise output_message(output, "kubectl #{args.inspect} failed") unless output.exit_code.zero?
        JSON.parse(output.stdout)
      rescue JSON::ParserError => e
        raise "decode kubectl output: #{e.message}"
      end

      def items(*args)
        kubectl(*args).fetch('items', [])
      end

      def remote_json(url, pod: 'vmalertmanager-vm-0')
        output = @runner.run('kubectl', 'exec', '-n', 'monitoring', pod, '--', 'wget', '-qO-', url)
        raise output_message(output, "request failed: #{url}") unless output.exit_code.zero?
        JSON.parse(output.stdout)
      end

      def conditions(object)
        object.dig('status', 'conditions') || []
      end

      def object_name(object)
        "#{object.dig('metadata', 'namespace')}/#{object.dig('metadata', 'name')}"
      end

      def age(value)
        @now.call - Time.iso8601(value.to_s)
      rescue ArgumentError
        raise "parse timestamp #{value.inspect}: invalid timestamp"
      end

      def nodes
        bad = items('get', 'nodes').reject { |n| conditions(n).any? { |c| c['type'] == 'Ready' && c['status'] == 'True' } }.map { |n| n.dig('metadata', 'name') }
        result('nodes', bad, 'all nodes Ready', "#{bad.length} nodes not Ready")
      end

      def kube_vip
        pods = items('get', 'pods', '-n', 'kube-system', '-l', 'app.kubernetes.io/name=kube-vip')
        bad = pods.reject { |p| p.dig('status', 'phase') == 'Running' && (p.dig('status', 'containerStatuses') || []).all? { |c| c['ready'] } }.map { |p| p.dig('metadata', 'name') }
        result('kube-vip', pods.empty? ? ['missing'] : bad, "#{pods.length} kube-vip pods ready", 'kube-vip pod readiness failed', bad)
      end

      def cilium
        output = @runner.run('kubectl', 'exec', '-n', 'kube-system', 'ds/cilium', '--', 'cilium-dbg', 'status', '--brief')
        detail = [output.stdout, output.stderr].map(&:strip).reject(&:empty?).join("\n")
        result('cilium', output.exit_code.zero? && detail == 'OK' ? [] : ['failed'], 'Cilium status OK', 'Cilium status check failed', detail.empty? ? [] : [detail])
      end

      def pods
        bad = items('get', 'pods', '-A').filter_map do |p|
          phase = p.dig('status', 'phase').to_s
          next if phase == 'Succeeded'
          containers = p.dig('status', 'containerStatuses') || []
          waiting = containers.filter_map { |c| c.dig('state', 'waiting', 'reason') }.reject(&:empty?)
          ready = containers.count { |c| c['ready'] }
          next if phase == 'Running' && waiting.empty? && (containers.empty? || ready == containers.length)
          reason = waiting.join(',')
          reason = phase if reason.empty?
          reason = "#{ready}/#{containers.length} ready" if reason.empty?
          "#{object_name(p)}: #{reason}"
        end
        result('pods', bad, 'all active pods ready', "#{bad.length} active pods not ready", bad.first(30))
      end

      def deployments
        bad = items('get', 'deploy', '-A').filter_map do |d|
          desired = d.fetch('spec', {}).fetch('replicas', 1)
          ready = d.dig('status', 'readyReplicas') || 0
          available = d.dig('status', 'availableReplicas') || 0
          "#{object_name(d)}: #{ready}/#{desired} ready" unless ready == desired && available == desired
        end
        result('deployments', bad, 'all deployments available', "#{bad.length} deployments unavailable")
      end

      def service_accounts
        pods = items('get', 'pods', '-A')
        accounts = items('get', 'serviceaccount', '-A').map { |a| object_name(a) }
        bad = pods.filter_map do |p|
          next if %w[Succeeded Failed].include?(p.dig('status', 'phase'))
          account = p.dig('spec', 'serviceAccountName').to_s
          account = 'default' if account.empty?
          "#{object_name(p)}: ServiceAccount #{account} is missing" unless accounts.include?("#{p.dig('metadata', 'namespace')}/#{account}")
        end
        summary = bad.length == 1 ? '1 active pod has a missing ServiceAccount' : "#{bad.length} active pods have a missing ServiceAccount"
        result('service-accounts', bad, 'all active pods have ServiceAccounts', summary)
      end

      def readiness_failures(resources, kind, ignore_suspended)
        resources.filter_map do |r|
          next if ignore_suspended && r.dig('spec', 'suspend')
          ready = conditions(r).reverse.find { |c| c['type'] == 'Ready' }
          reconciling = conditions(r).reverse.find { |c| c['type'] == 'Reconciling' && c['status'] == 'True' }
          next if ready && ready['status'] == 'True'
          transition = if reconciling && reconciling['reason'] == 'Progressing' && (!ready || ready['reason'] == 'Progressing')
                         reconciling['lastTransitionTime']
                       elsif !reconciling && ready && ready['reason'] == 'Progressing'
                         ready['lastTransitionTime']
                       end
          begin
            next if transition && !transition.empty? && age(transition) <= 600
          rescue RuntimeError
            # An invalid timestamp cannot grant the reconciliation grace period.
          end
          next "#{kind} #{object_name(r)}: Ready condition missing" unless ready
          reason = ready['reason'].to_s
          reason = "Ready=#{ready['status']}" if reason.empty?
          reason += ": #{ready['message']}" unless ready['message'].to_s.empty?
          "#{kind} #{object_name(r)}: #{reason}"
        end
      end

      def gitops
        bad = [%w[GitRepository gitrepository], %w[Kustomization kustomization], %w[HelmRelease helmrelease]].flat_map do |kind, resource|
          readiness_failures(items('get', resource, '-A'), kind, true)
        end
        result('gitops', bad, 'all unsuspended Flux resources Ready', "#{bad.length} Flux resources not Ready")
      end

      def external_secrets
        bad = readiness_failures(items('get', 'externalsecret', '-A'), 'ExternalSecret', false)
        result('external-secrets', bad, 'all ExternalSecrets Ready', "#{bad.length} ExternalSecret#{bad.length == 1 ? '' : 's'} not Ready")
      end
    end
  end
end
