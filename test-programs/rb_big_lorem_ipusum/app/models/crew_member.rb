# frozen_string_literal: true

module RbBigLoremIpusum
  module App
    module Models
      class CrewMember
        attr_reader :name, :role, :certifications, :on_call
        alias on_call? on_call

        def initialize(name:, role:, certifications:, on_call: false)
          @name = name
          @role = role
          @certifications = certifications
          @on_call = on_call
        end
      end
    end
  end
end
