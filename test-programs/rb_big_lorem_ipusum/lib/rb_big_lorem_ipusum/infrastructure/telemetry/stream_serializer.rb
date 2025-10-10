# frozen_string_literal: true

require 'time'

module RbBigLoremIpusum
  module Infrastructure
    module Telemetry
      # Encodes telemetry entries as verbose JSON for large diff surfaces.
      class StreamSerializer
        def serialize(entries)
          entries.map.with_index do |entry, index|
            decorate(entry.merge(serial: index + 1, checksum: checksum(entry)))
          end
        end

        private

        def decorate(entry)
          entry.merge(rendered_at: Time.now.utc.iso8601)
        end

        def checksum(entry)
          entry.to_s.each_byte.reduce(0) { |acc, byte| (acc * 33) ^ byte }
        end
      end
    end
  end
end
