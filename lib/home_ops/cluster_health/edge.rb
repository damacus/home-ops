# frozen_string_literal: true

require 'base64'
require 'digest/sha1'
require 'openssl'
require 'securerandom'
require 'socket'

module HomeOps
  module ClusterHealth
    class Checker
      def executable(name)
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |p| File.join(p, name) }.find { |p| File.file?(p) && File.executable?(p) }
      end

      def edge_smoke(options)
        brew = '/opt/homebrew/opt/curl/bin/curl'
        curl = if File.exist?(brew)
                 version = @runner.run(brew, '-V')
                 brew if version.exit_code.zero? && version.stdout.include?('HTTP3')
               end
        curl ||= executable('curl')
        return { name: 'edge-smoke', status: 'fail', summary: 'edge smoke failed', details: ['curl is required'] } unless curl
        checks = [['Home Assistant', 'https://home-assistant.ironstone.casa/'], ['code-server', 'https://code.ironstone.casa/'], ['Echo Server', 'https://echo-server.ironstone.casa/']]
        checks << ['ESPHome canary', 'https://esphome-traefik.ironstone.casa/'] if options[:include_esphome_canary]
        details, failures = ["[INFO] Using curl: #{curl}"], []
        checks.each do |name, url|
          versions = %w[http1.1 http2]
          versions << 'http3' unless options[:skip_http3]
          versions.each do |version|
            ok, detail = http_check(curl, name, url, version)
            details << detail
            failures << detail unless ok
          end
        end
        sockets = [['Home Assistant WebSocket', 'home-assistant.ironstone.casa', '/api/websocket', 'auth_required', nil]]
        if options[:include_esphome_canary] && !options[:esphome_websocket_path].to_s.empty?
          sockets << ['ESPHome canary WebSocket', 'esphome-traefik.ironstone.casa', options[:esphome_websocket_path], options[:esphome_websocket_contains], 'https://zitadel.damacus.io/oauth/v2/authorize']
        end
        sockets.each do |name, host, path, contains, redirect|
          ok, detail = websocket_check(name, host, path, contains, redirect)
          details << detail
          failures << detail unless ok
        end
        result('edge-smoke', failures, 'edge smoke passed', 'edge smoke failed', details)
      end

      def http_check(curl, name, url, version)
        flag = version == 'http3' ? '--http3-only' : "--#{version}"
        output = @runner.run(curl, '--silent', '--show-error', '--output', '/dev/null', '--write-out', '%{http_code}', '--max-time', '20', flag, url)
        unless output.exit_code.zero?
          return [true, "[WARN] #{name} #{version}: local curl build lacks HTTP/3 support"] if version == 'http3' && output.stderr.include?('option --http3-only')
          return [false, "[FAIL] #{name} #{version}: curl exited #{output.exit_code}: #{output.stderr.strip}"]
        end
        begin
          code = Integer(output.stdout.strip, 10)
        rescue ArgumentError
          return [false, "[FAIL] #{name} #{version}: unexpected status output #{output.stdout.inspect}"]
        end
        return [false, "[FAIL] #{name} #{version}: unexpected HTTP status #{code}"] unless [200, 301, 302, 308].include?(code)
        [true, "[PASS] #{name} #{version}: #{code}"]
      end

      def websocket_check(name, host, path, contains, redirect)
        key = Base64.strict_encode64(SecureRandom.random_bytes(16))
        tcp = ssl = nil
        Timeout.timeout(20) do
          tcp = Socket.tcp(host, 443, connect_timeout: 20)
          context = OpenSSL::SSL::SSLContext.new
          context.set_params(min_version: OpenSSL::SSL::TLS1_2_VERSION)
          ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
          ssl.hostname = host
          ssl.sync_close = true
          ssl.connect
          ssl.post_connection_check(host)
          ssl.write("GET #{path} HTTP/1.1\r\nHost: #{host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\nOrigin: https://#{host}\r\n\r\n")
          status = ssl.gets
          raise 'read handshake: unexpected EOF' unless status
          headers = {}
          loop do
            line = ssl.gets
            raise 'read handshake headers: unexpected EOF' unless line
            break if line.strip.empty?
            k, v = line.split(':', 2)
            raise 'read handshake headers: invalid header' unless v
            headers[k.downcase] = v.strip
          end
          if redirect
            return [false, "[FAIL] #{name}: authenticated payload assertion requires a session; this probe only verifies the login redirect"] unless contains.to_s.empty?
            return [false, "[FAIL] #{name}: expected authentication redirect"] unless %w[302 303 307 308].include?(status.split[1])
            begin
              actual, expected = URI.parse(headers['location'].to_s), URI.parse(redirect)
              valid = actual.userinfo.nil? && actual.fragment.nil? && actual.scheme == 'https' && actual.host&.casecmp?(expected.host) && actual.port == expected.port && actual.path == expected.path
            rescue URI::InvalidURIError
              valid = false
            end
            return [false, "[FAIL] #{name}: missing or unexpected authentication redirect destination"] unless valid
            return [true, "[PASS] #{name}: authentication redirect verified; authenticated handshake not checked"]
          end
          return [false, "[FAIL] #{name}: missing 101 response"] unless status.include?('101 Switching Protocols')
          expected = Base64.strict_encode64(Digest::SHA1.digest(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
          return [false, "[FAIL] #{name}: invalid Sec-WebSocket-Accept"] unless headers['sec-websocket-accept'] == expected
          unless contains.to_s.empty?
            payload = read_websocket_frame(ssl)
            return [false, "[FAIL] #{name}: expected payload containing #{contains.inspect}, got #{payload.inspect}"] unless payload.include?(contains)
          end
          [true, "[PASS] #{name}: websocket handshake succeeded"]
        end
      rescue StandardError => e
        [false, "[FAIL] #{name}: #{e.message}"]
      ensure
        ssl&.close
        tcp&.close unless tcp&.closed?
      end

      def read_exact(io, length)
        buffer = ''.b
        while buffer.bytesize < length
          part = io.read(length - buffer.bytesize)
          raise 'read WebSocket payload: unexpected EOF' unless part
          buffer << part
        end
        buffer
      end

      def read_websocket_frame(io)
        header = read_exact(io, 2).bytes
        length = header[1] & 0x7f
        length = read_exact(io, 2).unpack1('n') if length == 126
        length = read_exact(io, 8).unpack1('Q>') if length == 127
        mask = read_exact(io, 4).bytes if header[1] & 0x80 != 0
        raise 'WebSocket frame exceeds 1 MiB' if length > 1 << 20
        payload = read_exact(io, length)
        payload = payload.bytes.each_with_index.map { |v, i| v ^ mask[i % 4] }.pack('C*') if mask
        payload
      end
    end
  end
end
