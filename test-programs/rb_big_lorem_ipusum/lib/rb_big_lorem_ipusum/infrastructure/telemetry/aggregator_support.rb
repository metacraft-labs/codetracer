# frozen_string_literal: true

module RbBigLoremIpusum
  module Infrastructure
    module Telemetry
      module AggregatorSupport
        def build_latency_trace(entry)
          {
            ship: entry[:ship],
            metrics: entry[:cycles].each_slice(2).map do |cycle, destination|
              next unless destination

              { destination: destination, latency: (cycle.hash % 200) + 20 }
            end.compact
          }
        end

        def serializer_for
          Processors::StreamSerializer.new
        end
      end
    end
  end
end
