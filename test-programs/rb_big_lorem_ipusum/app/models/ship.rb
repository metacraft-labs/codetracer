# frozen_string_literal: true

module RbBigLoremIpusum
  module App
    module Models
      class Ship
        attr_reader :identifier, :model, :crew, :cargo

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
