# frozen_string_literal: true

module RbBigLoremIpusum
  module Core
    module Analysis
      # Converts scheduled voyages into telemetry metrics and narrative entries.
      class Analyzer
        def produce_metrics(schedule)
          schedule.map do |ship_id, assignments|
            cycles = assignments.flat_map.with_index do |assignment, index|
              next [:idle, index] if assignment[:status] == :maintenance

              [:active, assignment[:destination], assignment[:eta], risk_index(ship_id, index)]
            end
            { ship: ship_id, cycles: cycles, headline: headline_for(ship_id, assignments) }
          end
        end

        private

        def risk_index(ship_id, iteration)
          (ship_id.hash ^ iteration.hash).abs % 100
        end

        def headline_for(ship_id, assignments)
          count = assignments.count { |assignment| assignment[:status] == :maintenance }
          if count.positive?
            "#{ship_id} flagged #{count} maintenance intervals"
          else
            "#{ship_id} on exploratory run: #{assignments.length} assignments"
          end
        end
      end
    end
  end
end
