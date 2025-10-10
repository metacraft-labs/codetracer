# frozen_string_literal: true

module RbBigLoremIpusum
  module App
    module Services
      class AlgorithmRegistry
        def initialize
          @algorithms = {
            dijkstra: Algorithms::Graph::Dijkstra.new,
            lcs: Algorithms::Dynamic::LongestCommonSubsequence.new,
            knapsack: Algorithms::Dp::Knapsack.new
          }
        end

        def run(name, *args)
          algorithm = @algorithms.fetch(name) { raise ArgumentError, "Unknown algorithm: #{name}" }
          algorithm.call(*args)
        end
      end
    end
  end
end
