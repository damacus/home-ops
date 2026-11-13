# frozen_string_literal: true

module HomeOps
  module ClusterHealth
    class Checker
      def cnpg_clusters
        bad = items('get', 'clusters.postgresql.cnpg.io', '-A').filter_map do |c|
          desired = c.dig('status', 'instances').to_i
          desired = c.dig('spec', 'instances').to_i if desired.zero?
          ready = c.dig('status', 'readyInstances').to_i
          phase = c.dig('status', 'phase').to_s
          "#{object_name(c)}: #{phase}, ready #{ready}/#{desired}" unless phase == 'Cluster in healthy state' && ready == desired
        end
        result('cnpg-clusters', bad, 'all CNPG clusters healthy', "#{bad.length} CNPG clusters unhealthy")
      end

      def cnpg_backups
        backups = items('get', 'backups.postgresql.cnpg.io', '-A').group_by { |b| "#{b.dig('metadata', 'namespace')}/#{b.dig('spec', 'cluster', 'name')}" }
        clusters = items('get', 'clusters.postgresql.cnpg.io', '-A')
        schedules = items('get', 'scheduledbackups.postgresql.cnpg.io', '-A').map { |s| "#{s.dig('metadata', 'namespace')}/#{s.dig('spec', 'cluster', 'name')}" }
        bad, details = [], []
        clusters.each do |c|
          key = object_name(c)
          if c.dig('metadata', 'annotations', 'cnpg.io/hibernation') == 'on' || conditions(c).any? { |v| v['type'] == 'cnpg.io/hibernation' && v['status'] == 'True' }
            details << "#{key}: hibernated, backup/WAL check skipped"
            next
          end
          unless schedules.include?(key)
            details << "#{key}: no ScheduledBackup configured, backup/WAL check skipped"
            next
          end
          list = (backups[key] || []).sort_by do |b|
            value = b.dig('status', 'startedAt').to_s
            value = b.dig('metadata', 'creationTimestamp').to_s if value.empty?
            Time.iso8601(value) rescue Time.utc(1)
          end
          latest = list.last
          success = list.reverse.find { |b| b.dig('status', 'phase') == 'completed' }
          phase = latest ? latest.dig('status', 'phase').to_s : 'missing'
          phase = 'unknown' if phase.empty?
          completed = success&.dig('status', 'stoppedAt').to_s
          if completed.empty?
            details << "#{key}: latest=#{phase}, last_success=-"
          else
            begin
              details << format('%s: latest=%s, last_success=%s (age=%.1f hours)', key, phase, completed, age(completed) / 3600)
            rescue RuntimeError => e
              bad << "#{key}: #{e.message}"
            end
          end
          if !latest
            bad << "#{key}: no Backup resources found"
          elsif phase == 'failed'
            error = latest.dig('status', 'error').to_s
            bad << "#{key}: latest backup failed: #{error.empty? ? 'unknown error' : error}"
          elsif phase == 'started'
            start = latest.dig('status', 'startedAt').to_s
            start = latest.dig('metadata', 'creationTimestamp').to_s if start.empty?
            begin
              bad << "#{key}: latest backup still started since #{start}" if age(start) > 1800
            rescue RuntimeError => e
              bad << "#{key}: #{e.message}"
            end
          end
          if !success
            bad << "#{key}: no successful backup found"
          elsif completed.empty?
            bad << "#{key}: last successful backup has no completion timestamp"
          else
            begin
              hours = age(completed) / 3600
              bad << format('%s: last successful backup is %.1f hours old (maximum 30 hours)', key, hours) if hours > 30
            rescue RuntimeError
              # The invalid completion time was already reported above.
            end
          end
          archive = archive_status(c.dig('metadata', 'namespace'), c.dig('metadata', 'name'))
          (archive[:status] == 'fail' ? bad : details).concat(archive[:details])
        end
        result('cnpg-backups', bad, 'all configured CNPG backups and WAL archiving healthy', "#{bad.length} CNPG backup/WAL issues", bad + details)
      end

      def archive_status(namespace, name)
        output = @runner.run('kubectl', 'cnpg', 'status', '-n', namespace, name)
        unless output.exit_code.zero?
          return { name: 'cnpg-wal', status: 'fail', summary: 'cnpg status failed', details: ["#{namespace}/#{name}: #{output_message(output, 'cnpg status failed')}"] }
        end
        waiting, failing = '', false
        output.stdout.each_line do |line|
          line = line.strip
          failing = line.include?('Failing') if line.start_with?('Working WAL archiving:')
          waiting = line.split(':').last.strip if line.start_with?('WALs waiting to be archived:')
        end
        bad = []
        bad << "#{namespace}/#{name}: WAL archiving failing" if failing
        bad << "#{namespace}/#{name}: #{waiting} WALs waiting" unless ['', '0'].include?(waiting)
        result('cnpg-wal', bad, 'WAL archiving checked', 'WAL archiving unhealthy')
      end

      def alert_detail(metric)
        resource = %w[deployment statefulset daemonset job_name pod service].map { |k| metric[k] }.find { |v| v && !v.empty? } || '-'
        "#{metric['alertname'].to_s.empty? ? 'unknown' : metric['alertname']}: #{metric['namespace'].to_s.empty? ? '-' : metric['namespace']}/#{resource}"
      end

      def grafana_alerts
        query = 'ALERTS{alertstate="firing",alertname!~"Watchdog|InfoInhibitor"}'
        data = remote_json("http://vmsingle-vm.monitoring.svc.cluster.local:8428/api/v1/query?query=#{URI.encode_www_form_component(query)}")
        details = (data.dig('data', 'result') || []).map { |r| alert_detail(r['metric'] || {}) }
        result('grafana-alerts', details, 'no firing actionable alerts', "#{details.length} firing actionable alerts")
      end

      def alertmanager
        data = remote_json('http://localhost:9093/api/v2/alerts')
        details = data.select { |a| a.dig('status', 'state') == 'active' && !%w[Watchdog InfoInhibitor].include?(a.dig('labels', 'alertname')) }.map { |a| alert_detail(a['labels'] || {}) }
        result('alertmanager', details, 'no active actionable Alertmanager alerts', "#{details.length} active actionable Alertmanager alerts")
      end

      def log_noise(period, top)
        query = "sum(count_over_time({namespace=~\".+\"}[#{period}])) by (app)"
        output = @runner.run('kubectl', 'exec', '-n', 'monitoring', 'deploy/loki-gateway', '--', 'wget', '-qO-', "http://localhost:8080/loki/api/v1/query?query=#{URI.encode_www_form_component(query)}&limit=100")
        unless output.exit_code.zero?
          return { name: 'log-noise', status: 'fail', summary: 'log-noise query failed', details: [output_message(output, 'Loki query failed')] }
        end
        begin
          data = JSON.parse(output.stdout)
        rescue JSON::ParserError => e
          return { name: 'log-noise', status: 'fail', summary: 'log-noise query returned invalid JSON', details: [e.message] }
        end
        rows = (data.dig('data', 'result') || []).filter_map do |entry|
          value = entry['value'] || []
          next if value.length < 2
          raise ArgumentError, "unsupported metric value #{value[1].inspect}" unless value[1].is_a?(Numeric) || value[1].is_a?(String)
          app = entry.dig('metric', 'app').to_s
          [app.empty? ? 'unknown' : app, Float(value[1])]
        end.sort_by { |_, count| -count }.first(top)
        { name: 'log-noise', status: 'pass', summary: "top #{rows.length} log producers over #{period}", details: rows.map { |app, count| format('%s: %.0f', app, count) } }
      rescue ArgumentError => e
        { name: 'log-noise', status: 'fail', summary: 'log-noise query returned invalid data', details: [e.message] }
      end
    end
  end
end
