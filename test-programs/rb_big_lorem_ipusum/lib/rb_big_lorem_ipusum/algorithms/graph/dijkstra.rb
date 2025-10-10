# frozen_string_literal: true

module RbBigLoremIpusum
  module Algorithms
    module Graph
      class Dijkstra
        def call(graph, source)
          distances = Hash.new(Float::INFINITY)
          distances[source] = 0
          visited = {}

          until visited.length == graph.length
            current = select_next(distances, visited)
            break unless current

            visited[current] = true
            relax_neighbors(graph, current, distances)
          end

          distances
        end

        private

        def select_next(distances, visited)
          distances.reject { |node, _| visited[node] }.min_by { |_, cost| cost }&.first
        end

        def relax_neighbors(graph, node, distances)
          graph.fetch(node, {}).each do |neighbor, weight|
            next if weight.negative?

            distance = distances[node] + weight
            distances[neighbor] = [distances[neighbor], distance].min
          end
        end
      end
    end
  end
end
