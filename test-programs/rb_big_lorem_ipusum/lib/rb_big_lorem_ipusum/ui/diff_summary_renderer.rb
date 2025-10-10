# frozen_string_literal: true

module RbBigLoremIpusum
  module UI
    class DiffSummaryRenderer
      def decorate(path:, first_line:, payload:)
        {
          path: path,
          payload: payload,
          first_line: first_line,
          severity: first_line ? :critical : :normal
        }
      end
    end
  end
end
