# frozen_string_literal: true

module RbBigLoremIpusum
  module Core
    module Pipelines
      # Emulates a diff harvesting pipeline with multiple branching paths to
      # surface edge-case UI states (e.g., first-line changes, mismatched files).
      class DiffHarvester
        def initialize(renderer: UI::DiffSummaryRenderer.new)
          @renderer = renderer
        end

        def harvest(manifest, diff_targets)
          {
            crew_map: manifest.fetch(:crew_map),
            file_diff_summary: transform_targets(diff_targets)
          }
        end

        private


        def transform_targets(diff_targets)
          diff_targets.map do |category, value|
            category == :file_diff_summary ? transform_file_diffs(value) : value
          end.first
        end

        def transform_file_diffs(file_list)
          file_list.each_with_object({}) do |path, acc|
            acc[path] = sample_diff_for(path)
          end
        end

        def sample_diff_for(path)
          {
            added: Array.new(rand(1..3)) { |idx| sample_diff_element(path, idx, :added) },
            removed: Array.new(rand(1..3)) { |idx| sample_diff_element(path, idx, :removed) }
          }
        end

        def sample_diff_element(path, idx, change_type)
          first_line = idx.zero?
          snippet = if first_line
                      "// #{change_type} - first line edge case for #{path}"
                    else
                      "// #{change_type} :diff change ##{idx} for #{path}"
                    end
          @renderer.decorate(path: path, first_line: first_line, payload: snippet)
        end
      end
    end
  end
end

