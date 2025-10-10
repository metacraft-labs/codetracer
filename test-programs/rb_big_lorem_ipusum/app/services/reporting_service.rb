# frozen_string_literal: true

module RbBigLoremIpusum
  module App
    module Services
      class ReportingService
        def initialize(storage: Infrastructure::Storage::ArchiveService.new)
          @storage = storage
        end

        def persist(manifest, diffs, telemetry)
          log_entries = build_entries(manifest, diffs, telemetry)
          log_entries.each_with_index do |entry, index|
            path = "reports/#{entry.ship}/entry-#{index}.json"
            @storage.snapshot(entry: entry, path: path)
          end
          log_entries
        end

        private

        def build_entries(manifest, diffs, telemetry)
          ships = manifest.fetch(:ships)
          ships.map do |ship|
            context = {
              diffs: diffs.fetch(:file_diff_summary, {})
                              .select { |path, _| path.include?(ship.identifier) },
              telemetry: telemetry.fetch(:diff_rendering, [])
                                   .find { |entry| entry[:ship] == ship.identifier }
            }
            Models::LogEntry.new(
              ship: ship.identifier,
              level: :info,
              message: "Generated report for #{ship.identifier}",
              context: context
            )
          end
        end
      end
    end
  end
end
