# frozen_string_literal: true

module RbBigLoremIpusum
  module SpecSupport
    module Factories
      module_function

      def ship(identifier: 'RB-000')
        crew = Array.new(3) do |index|
          App::Domain::Entities::CrewMember.new(
            name: "Crew #{index}",
            role: %w[pilot engineer analyst][index % 3],
            certifications: %W[c#{index} d#{index}],
            on_call: index.even?
          )
        end
        App::Domain::Entities::Ship.new(
          identifier: identifier,
          model: 'Explorer',
          crew: crew,
          cargo: %w[module-alpha module-beta]
        )
      end
    end
  end
end
