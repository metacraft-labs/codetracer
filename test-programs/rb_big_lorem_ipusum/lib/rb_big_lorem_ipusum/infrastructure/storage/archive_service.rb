# frozen_string_literal: true

module RbBigLoremIpusum
  module Infrastructure
    module Storage
      # Stores manifest snapshots to both memory and file adapters to simulate
      # multi-target persistence in the diff scenarios.
      class ArchiveService
        def initialize(memory: MemoryBuffer.new, file: FileSystemAdapter.new)
          @memory = memory
          @file = file
        end

        def snapshot(manifest)
          payload = manifest.merge(serialized_at: Time.now.utc)
          @memory.persist(:manifest, payload)
          @file.persist('manifests/latest.json', payload)
          payload
        end
      end
    end
  end
end
