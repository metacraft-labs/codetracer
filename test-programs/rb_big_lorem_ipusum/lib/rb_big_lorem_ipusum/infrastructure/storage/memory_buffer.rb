# frozen_string_literal: true

module RbBigLoremIpusum
  module Infrastructure
    module Storage
      class MemoryBuffer
        attr_reader :store

        def initialize
          @store = Hash.new { |hash, key| hash[key] = [] }
        end

        def persist(key, payload)
          @store[key] << payload
        end
      end
    end
  end
end
