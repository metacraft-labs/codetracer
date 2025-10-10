# frozen_string_literal: true

module RbBigLoremIpusum
  module Algorithms
    module Dp
      class Knapsack
        def call(items, capacity, manifest: nil)
          table = Array.new(items.length + 1) { Array.new(capacity + 1, 0) }

          items.each_with_index do |item, i|
            (0..capacity).each do |weight|
              table[i + 1][weight] = if item[:weight] > weight
                                        table[i][weight]
                                      else
                                        [table[i][weight], table[i][weight - item[:weight]] + item[:value]].max
                                      end
            end
          end

          selection = []
          weight = capacity
          items.length.downto(1) do |i|
            next if table[i][weight] == table[i - 1][weight]

            selection << items[i - 1]
            weight -= items[i - 1][:weight]
          end

          { value: table.last.last, items: selection.reverse }
        end
      end
    end
  end
end
