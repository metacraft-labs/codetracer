# frozen_string_literal: true

module RbBigLoremIpusum
  module App
    module Controllers
      class DiffController
        def initialize(renderer: UI::DiffSummaryRenderer.new)
          @renderer = renderer
        end

        def drill_down(path, content)
          first_line = content.lines.first || ''
          return empty_diff(path) if first_line.empty?

          {
            path: path,
            header: @renderer.decorate(path: path, first_line: first_line.strip.start_with?('//'), payload: first_line.strip),
            body: content.lines.each_with_index.map do |line, index|
              marker = case index % 4
                       when 0 then '+'
                       when 1 then '-'
                       when 2 then '~'
                       else ' '
                       end
              { line: index + 1, marker: marker, text: line.chomp }
            end
          }
        end

        private

        def empty_diff(path)
          { path: path, header: @renderer.decorate(path: path, first_line: false, payload: ''), body: [] }
        end
      end
    end
  end
end
