# frozen_string_literal: true

module RbBigLoremIpusum
  module Support
    # Utility responsible for instantiating structured objects from raw hashes.
    module Loader
      module_function

      def symbolize_keys(hash)
        hash.each_with_object({}) do |(key, value), acc|
          acc[key.to_sym] = value.is_a?(Hash) ? symbolize_keys(value) : value
        end
      end

      def deep_copy(data)
        Marshal.load(Marshal.dump(data))
      end
    end
  end
end
