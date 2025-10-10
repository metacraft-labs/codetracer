# frozen_string_literal: true

module RbBigLoremIpusum
  module App
    module Controllers
      class NavigationController
        def initialize(algorithm_registry: Services::AlgorithmRegistry.new)
          @algorithm_registry = algorithm_registry
        end

        def routes_for(ship)
          knapsack = @algorithm_registry.run(:knapsack, sample_items(ship.identifier), 300)
          waypoints = Array.new(8) { |index| "waypoint-#{ship.identifier}-#{index}" }
          { ship: ship.identifier, cargo_plan: knapsack, waypoints: waypoints }
        end

        private

        def sample_items(seed)
          Array.new(12) do |index|
            {
              name: "module-#{seed}-#{index}",
              weight: 10 + (seed.hash + index) % 50,
              value: 50 + (seed.hash ^ index).abs % 200
            }
          end
        end
      end
    end
  end
end
