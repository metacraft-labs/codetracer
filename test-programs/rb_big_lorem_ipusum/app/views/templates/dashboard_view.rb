# frozen_string_literal: true

module RbBigLoremIpusum
  module App
    module Views
      module Templates
        class DashboardView
          def initialize(renderer: UI::ConsoleDashboard.new)
            @renderer = renderer
          end

          def call(context)
            @renderer.render(**context)
          end
        end
      end
    end
  end
end
