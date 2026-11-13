# frozen_string_literal: true

require 'rbconfig'

module HomeOps
  module Provisioning
    module Flash
      def run_flash(args)
        catch(:help) do
          flags = options(args, 'provisioning flash <artifact> <device> [--dry-run]', booleans: %w[dry-run])
          positionals(args, 2, 'provisioning flash <artifact> <device> [--dry-run]')
          artifact, device = args.map { |value| File.expand_path(value) }
          return json('source' => artifact, 'device' => device, 'remote_download' => false) if flags['dry-run']
          set, = validate_artifacts(artifact)
          target = inspect_flash_device(device)
          image_size = xz_uncompressed_size(set['image'])
          raise Error, "image is #{image_size} bytes but target capacity is #{target['size']} bytes" if target['size'].zero? || image_size > target['size']
          $stderr.puts "Target: #{target['device']} size=#{target['size']} bytes model=#{target['model']}"
          confirmation(target['device'], 'to overwrite it')
          stream_image_to_device(set['image'], target['raw_device'])
          run('sync', stderr: true)
          run('diskutil', 'eject', target['device'], stderr: true) if darwin?
        end
      end

      def darwin? = RbConfig::CONFIG['host_os'].include?('darwin')

      def stream_image_to_device(image, device)
        # Both processes are waited: a decompressor failure must not look like a successful write.
        Open3.pipeline_r(['xz', '-dc', image]) do |reader, decompressors|
          success = system('sudo', 'dd', "of=#{device}", 'bs=4M', 'conv=fsync', 'status=progress', in: reader, out: $stderr, err: $stderr)
          reader.close
          raise Error, 'image write failed' unless success
          raise Error, 'image decompression failed' unless decompressors.all? { |process| process.value.success? }
        end
      end

      def inspect_flash_device(device)
        raise Error, "flash target is not a block device: #{device}" unless File.blockdev?(device)
        return inspect_darwin_device(device) if darwin?
        raise Error, "flashing is unsupported on #{RbConfig::CONFIG['host_os']}" unless RbConfig::CONFIG['host_os'].include?('linux')
        disks = JSON.parse(capture('lsblk', '--json', '--bytes', '--paths', '--output', 'PATH,TYPE,SIZE,MODEL,MOUNTPOINTS', device)).fetch('blockdevices')
        raise Error, "flash target is not a whole disk: #{device}" unless disks.length == 1 && disks.first['type'] == 'disk'
        target = disks.first
        mounted = mounted_values(target)
        raise Error, "flash target has mounted filesystems: #{mounted.join(', ')}" unless mounted.empty?
        root = capture('findmnt', '--noheadings', '--output', 'SOURCE', '/')
        ancestry = capture('lsblk', '--inverse', '--noheadings', '--paths', '--output', 'PATH', root).split
        raise Error, "refusing the disk containing the live root filesystem: #{device}" if ancestry.include?(target['path'])
        { 'device' => target['path'], 'raw_device' => target['path'], 'size' => target.fetch('size').to_i, 'model' => first_nonempty(target['model'].to_s.strip, 'unknown') }
      end

      def mounted_values(node)
        [node['mountpoint'], *Array(node['mountpoints']), *Array(node['children']).flat_map { |child| mounted_values(child) }].compact.reject(&:empty?)
      end

      def diskutil_json(*args)
        argv = args.dup
        argv.insert(args.first == 'apfs' ? 2 : 1, '-plist')
        plist = capture('diskutil', *argv)
        JSON.parse(capture('plutil', '-convert', 'json', '-o', '-', '-', input: plist))
      end

      def inspect_darwin_device(device)
        info = diskutil_json('info', device)
        raise Error, "flash target is not a whole disk: #{device}" unless info['Whole']
        identifier = info.fetch('DeviceIdentifier')
        root = diskutil_json('info', '/')
        apfs = diskutil_json('apfs', 'list')
        root_disks = [root['ParentWholeDisk'], *apfs_physical_disks(apfs, first_nonempty(root['ParentWholeDisk'], root['DeviceIdentifier']), false)]
        raise Error, "refusing the disk containing the live root filesystem: #{device}" if root_disks.include?(identifier)
        listing = diskutil_json('list', device)
        Array(listing['AllDisksAndPartitions']).each do |disk|
          Array(disk['Partitions']).each do |partition|
            mount = diskutil_json('info', "/dev/#{partition.fetch('DeviceIdentifier')}")['MountPoint'].to_s
            raise Error, "flash target has mounted filesystems: #{mount}" unless mount.empty?
          end
        end
        raise Error, 'flash target has mounted filesystems: mounted APFS volume' if apfs_physical_disks(apfs, '', true).include?(identifier)
        { 'device' => "/dev/#{identifier}", 'raw_device' => "/dev/r#{identifier}", 'size' => info.fetch('TotalSize').to_i,
          'model' => first_nonempty(info['MediaName'], info['DeviceModel'], 'unknown') }
      end

      def apfs_physical_disks(apfs, identifier, mounted_only)
        Array(apfs['Containers']).flat_map do |container|
          matches = !identifier.empty? && container['ContainerReference'] == identifier
          matches ||= Array(container['Volumes']).any? do |volume|
            (!identifier.empty? && volume['DeviceIdentifier'] == identifier) || (mounted_only && !volume['MountPoint'].to_s.empty?)
          end
          next [] unless matches
          Array(container['PhysicalStores']).filter_map do |store|
            id = store['DeviceIdentifier'].to_s
            next if id.empty?
            first_nonempty(diskutil_json('info', "/dev/#{id}")['ParentWholeDisk'], id)
          end
        end.uniq
      end

      def first_nonempty(*values) = values.find { |value| !value.to_s.empty? }.to_s
    end
  end
end
