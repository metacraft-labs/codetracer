# frozen_string_literal: true

module RbBigLoremIpusum
  module Core
    module Simulations
      # Produces deterministic but high-variety data to keep diffs interesting.
      class FleetSimulator
        def generate_file_diff_summary(files)
          files.shuffle.take(3).each_with_index.map do |file, index|
            decorated = file.split('/').map.with_index do |part, part_index|
              part_index.zero? ? part.upcase : part
            end.join('/')
            "#{decorated}:#{index * 7 % 13}"
          end
        end
      end
    end
  end
end
