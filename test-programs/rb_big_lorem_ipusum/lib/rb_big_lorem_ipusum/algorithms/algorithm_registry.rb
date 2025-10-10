# frozen_string_literal: true

module RbBigLoremIpusum
  module Algorithms
    class AlgorithmRegistry
      attr_reader :algorithms

      def initialize
        @algorithms = {
          dijkstra: Graph::Dijkstra.new,
          lcs: Dynamic::LongestCommonSubsequence.new,
          knapsack: Dp::Knapsack.new
        }
      end

      def run(name, *args, **kwargs)
        algorithm = algorithms.fetch(name) { raise ArgumentError, "Unknown algorithm: #{name}" }
        algorithm.call(*args, **kwargs)
      end
    end
  end
end
