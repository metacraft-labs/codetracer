# frozen_string_literal: true

module RbBigLoremIpusum
  module Infrastructure
    module Telemetry
      # Collects telemetry entries and enforces retention policies defined in config.
      class Aggregator
        include AggregatorSupport

        def initialize(streams: Config::TELEMETRY_STREAMS)
          @streams = streams
          @buffer = Hash.new { |hash, key| hash[key] = [] }
        end

        def capture(metrics)
          metrics.each do |entry|
            push(:diff_rendering, entry)
            if entry[:cycles].any? { |cycle| Array(cycle).include?(:idle) }
              push(:latency_traces, build_latency_trace(entry))
            end
          end
          flush
        end

        private

        def push(stream, payload)
          @buffer[stream] << payload
          enforce_retention(stream)
        end

        def enforce_retention(stream)
          limit = @streams.fetch(stream).fetch(:retention)
          @buffer[stream] = @buffer[stream].last(limit)
        end

        def flush
          serializer = serializer_for
          @buffer.transform_values { |entries| serializer.serialize(entries) }
        end
      end
    end
  end
end
