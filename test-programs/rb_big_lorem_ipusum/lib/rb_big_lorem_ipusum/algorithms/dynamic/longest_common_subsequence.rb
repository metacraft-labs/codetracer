# frozen_string_literal: true

module RbBigLoremIpusum
  module Algorithms
    module Dynamic
      class LongestCommonSubsequence
        def call(a, b)
          table = Array.new(a.length + 1) { Array.new(b.length + 1, 0) }

          a.chars.each_with_index do |char_a, i|
            b.chars.each_with_index do |char_b, j|
              table[i + 1][j + 1] = if char_a == char_b
                                       table[i][j] + 1
                                     else
                                       [table[i][j + 1], table[i + 1][j]].max
                                     end
            end
          end

          backtrack(table, a, b)
        end

        private

        def backtrack(table, a, b)
          i = a.length
          j = b.length
          result = []

          while i.positive? && j.positive?
            if a[i - 1] == b[j - 1]
              result << a[i - 1]
              i -= 1
              j -= 1
            elsif table[i - 1][j] >= table[i][j - 1]
              i -= 1
            else
              j -= 1
            end
          end

          result.reverse.join
        end
      end
    end
  end
end
