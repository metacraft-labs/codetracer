# frozen_string_literal: true

module RbBigLoremIpusum
  module Config
    TELEMETRY_STREAMS = {
      latency_traces: { retention: 72, sampling: :adaptive },
      diff_rendering: { retention: 48, sampling: :burst },
      accessibility_events: { retention: 168, sampling: :all }
    }.freeze
  end
end
