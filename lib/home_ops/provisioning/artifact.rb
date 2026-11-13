# frozen_string_literal: true

require 'date'

module HomeOps
  module Provisioning
    module Artifact
      def artifact_paths(input)
        image = File.expand_path(input)
        image = image.delete_suffix('.sha256') if image.end_with?('.img.xz.sha256')
        image = image.delete_suffix('.manifest.json') + '.img.xz' if image.end_with?('.manifest.json')
        raise Error, "artifact must be a .img.xz image: #{input}" unless image.end_with?('.img.xz')
        { 'image' => image, 'checksum' => image + '.sha256', 'manifest' => image.delete_suffix('.img.xz') + '.manifest.json' }
      end

      def run_artifact(args)
        positionals(args, 2, 'provisioning artifact validate <artifact>')
        raise UsageError, 'usage: provisioning artifact validate <artifact>' unless args.first == 'validate'
        set, manifest = validate_artifacts(args.last)
        json({ 'release_id' => manifest['release_id'] }.merge(set))
      end

      def validate_artifacts(input)
        set = artifact_paths(input)
        set.each_value { |path| raise Error, "artifact is missing: #{path}" unless File.file?(path) }
        lines = File.readlines(set['checksum'])
        match = /\A([0-9a-fA-F]{64})\s+\*?(.+)\z/.match(lines.first.to_s.strip)
        unless lines.length == 1 && match && File.basename(match[2]) == File.basename(set['image'])
          raise Error, 'checksum sidecar must contain exactly the image hash and filename'
        end
        actual_hash = Digest::SHA256.file(set['image']).hexdigest
        manifest = JSON.parse(File.read(set['manifest']))
        release_id = File.basename(set['image']).delete_suffix('.img.xz')
        raise Error, 'artifact filename does not contain a canonical release ID' unless /\Aradxa-5b-plus-\d{8}-[0-9a-f]{12}\z/.match?(release_id)
        raise Error, 'manifest schema or release ID does not match artifact' unless manifest['schema_version'] == 1 && manifest['release_id'] == release_id
        commit = manifest['home_ops_commit'].to_s
        raise Error, 'manifest home-ops commit is not a full commit' unless /\A[0-9a-f]{40}\z/.match?(commit)
        raise Error, 'manifest home-ops commit does not match the release ID' unless release_id.end_with?(commit[0, 12])
        timestamp = manifest.fetch('timestamp')
        parts = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-](\d{2}):(\d{2}))\z/.match(timestamp.to_s)
        unless parts && Date.valid_date?(*parts.captures.first(3).map(&:to_i)) &&
               parts[4].to_i < 24 && parts[5].to_i < 60 && parts[6].to_i < 60 &&
               (!parts[7] || (parts[7].to_i < 24 && parts[8].to_i < 60))
          raise Error, 'manifest timestamp is not RFC 3339'
        end
        Time.iso8601(timestamp)
        unless manifest['board'] == App::PARAMETERS['BOARD'] && manifest['branch'] == App::PARAMETERS['BRANCH'] &&
               manifest['release'] == App::PARAMETERS['RELEASE'] && manifest['build_parameters'] == App::PARAMETERS
          raise Error, 'manifest build target does not match the approved build'
        end
        files = manifest.fetch('files')
        unless match[1].downcase == actual_hash && files.dig('image', 'sha256') == actual_hash
          raise Error, 'image checksum, checksum sidecar, and manifest do not agree'
        end
        set.each do |key, path|
          raise Error, 'manifest filenames do not match artifact set' unless files.dig(key, 'filename') == File.basename(path)
        end
        { 'k3s_binary' => 'k3s-arm64', 'k3s_airgap' => 'k3s-airgap-images-arm64.tar' }.each do |key, name|
          unless files.dig(key, 'filename') == name && /\A[0-9a-f]{64}\z/.match?(files.dig(key, 'sha256').to_s)
            raise Error, 'manifest K3s payload metadata is incomplete'
          end
        end
        raise Error, 'manifest K3s version does not match the cluster Plans' unless manifest['k3s_version'] == current_k3s_version
        raise Error, 'manifest Armbian commit does not match the pinned submodule' unless manifest['armbian_commit'] == armbian_commit
        [set, manifest]
      rescue KeyError => e
        raise Error, "artifact manifest is incomplete: #{e.message}"
      end
    end
  end
end
