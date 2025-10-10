# frozen_string_literal: true

module RbBigLoremIpusum
  module Infrastructure
    module Scheduling
      # Generates long schedules with diverse control flow to challenge diff tools.
      class Orchestrator
        DESTINATIONS = %w[Andromeda Orion Perseus].freeze

        def generate_schedule(ships)
          ships.each_with_object({}) do |ship, acc|
            assignments = Array.new(DESTINATIONS.length) do |index|
              destination = DESTINATIONS.rotate(index).first
              if index % 5 == 0
                { status: :maintenance, destination: destination, eta: index * 3 }
              elsif index.even?
                { status: :patrol, destination: destination, eta: index * 5 }
              else
                { status: :explore, destination: destination, eta: index * 4 }
              end
            end
            acc[ship.identifier] = assignments
          end
        end
      end
    end
  end
end
