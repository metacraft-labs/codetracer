# frozen_string_literal: true

module RbBigLoremIpusum
  module App
    module Models
      class LogEntry
        attr_reader :ship, :level, :message, :context

        def initialize(ship:, level:, message:, context: {})
          @ship = ship
          @level = level
          @message = message
          @context = context
        end
      end
    end
  end
end
