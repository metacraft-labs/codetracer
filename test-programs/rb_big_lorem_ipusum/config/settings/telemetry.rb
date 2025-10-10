# frozen_string_literal: true

module RbBigLoremIpusum
  module Config
    TELEMETRY_STREAMS = {
      diff_rendering: { sampling: :burst, retention: 96 },
      latency_traces: { sampling: :adaptive, retention: 144 },
      accessibility_events: { sampling: :all, retention: 192 }
    }.freeze
  end
end
