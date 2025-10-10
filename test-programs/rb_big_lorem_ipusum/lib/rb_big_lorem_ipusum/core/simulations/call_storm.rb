# frozen_string_literal: true

module RbBigLoremIpusum
  module Core
    module Simulations
      # Builds a dense call graph with recursive branches and frequent logging to
      # stress the tracing and event logging subsystems.
      class CallStorm
        DEFAULT_SEQUENCE = [3, 2].freeze

        def initialize(output: $stdout)
          @output = output
        end

        def execute(seed_sequence: DEFAULT_SEQUENCE)
          @output.puts "[CallStorm] scheduling seeds=#{seed_sequence.join(',')}"
          branches = seed_sequence.map do |seed|
            top = simulate_branch(seed)
            envelope = fold_envelope(seed)
            { seed: seed, top: top, envelope: envelope }
          end
          summarize(branches)
          { seeds: seed_sequence, branches: branches }
        end

        private

        def simulate_branch(seed)
          @output.puts "[CallStorm] simulate_branch seed=#{seed}"
          cascade([seed, 3].min, :root)
        end

        def cascade(depth, label)
          record_branch(depth, label)
          return base_case(depth, label) if depth <= 1

          next_depth = depth - 1
          left = cascade(next_depth, next_label(label, :left))
          right = cascade([depth - 2, 1].max, next_label(label, :right))

          merge_scores(left, right, depth, label)
        end

        def record_branch(depth, label)
          return unless depth >= 0

          if depth <= 3 || depth.even?
            @output.puts "[CallStorm] branch depth=#{depth} label=#{label}"
          end
        end

        def base_case(depth, label)
          score = (depth.abs + label.to_s.length) * 3
          { score: score, depth: 1, signature: "#{label}-base-#{score}" }
        end

        def next_label(label, direction)
          "#{label}_#{direction}".to_sym
        end

        def merge_scores(left, right, depth, label)
          weighted = weight_score(left[:score], right[:score], depth)
          combined_depth = [left[:depth], right[:depth]].max + 1
          signature = "#{label}-#{depth}-#{left[:signature]}-#{right[:signature]}"
          emit_progress(label, combined_depth, weighted)
          {
            score: weighted,
            depth: combined_depth,
            signature: signature
          }
        end

        def weight_score(left_score, right_score, depth)
          factor = (depth % 5) + 1
          (left_score + right_score + depth.abs) * factor
        end

        def emit_progress(label, depth, score)
          return unless depth % 2 == 0 || score.odd?

          @output.puts "[CallStorm] merge label=#{label} depth=#{depth} score=#{score}"
        end

        def fold_envelope(seed)
          accumulator = 0
          path_labels(seed).map.with_index do |symbol, index|
            accumulator = accumulate_envelope(accumulator, symbol, index, seed)
            maybe_log_envelope(seed, symbol, accumulator, index)
            {
              step: index,
              symbol: symbol,
              accumulator: accumulator
            }
          end
        end

        def path_labels(seed)
          base_symbols = %i[alpha beta gamma]
          limit = [seed + 2, 3].min
          base_symbols.cycle.take(limit)
        end

        def accumulate_envelope(value, symbol, index, seed)
          scale = scale_from_seed(seed, symbol)
          value + symbol.to_s.length + index + scale
        end

        def scale_from_seed(seed, symbol)
          base = (seed * symbol.to_s.bytes.sum) % 17
          base.zero? ? 1 : base
        end

        def maybe_log_envelope(seed, symbol, accumulator, index)
          return unless (index % 2).zero?

          @output.puts "[CallStorm] envelope seed=#{seed} symbol=#{symbol} accumulator=#{accumulator}"
        end

        def summarize(branches)
          total_score = branches.reduce(0) { |sum, branch| sum + branch[:top][:score] }
          depth_span = branches.map { |branch| branch[:top][:depth] }.max
          @output.puts "[CallStorm] summary total_score=#{total_score} depth_span=#{depth_span}"
        end
      end
    end
  end
end
