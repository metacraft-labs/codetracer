# frozen_string_literal: true

module RbBigLoremIpusum
  module Features
    module DiffDiagnostics
      # Computes synthetic diff anomalies so the demo can expose multi-file edge cases.
      class Analyzer
        def initialize(stream: $stdout)
          @stream = stream
        end

        def emit_summary(diff_targets)
          grouped = diff_targets.group_by { |path, _| path.split('/').first }
          grouped.each do |group, entries|
            @stream.puts "[DiffDiagnostics] #{group} => #{entries.length} target(s)"
          end
          grouped
        end
      end
    end
  end
end
