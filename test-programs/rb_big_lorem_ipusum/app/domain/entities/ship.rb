# frozen_string_literal: true

module RbBigLoremIpusum
  module App
    module Domain
      module Entities
        class Ship
          attr_reader :cargo, :crew, :identifier, :model

          def initialize(identifier:, model:, crew:, cargo: [])
            @identifier = identifier
            @model = model
            @crew = crew
            @cargo = cargo
          end
        end
      end
    end
  end
end
