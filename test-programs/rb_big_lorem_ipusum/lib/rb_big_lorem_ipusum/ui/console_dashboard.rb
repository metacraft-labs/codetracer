# frozen_string_literal: true

module RbBigLoremIpusum
  module UI
    # Renders summary data in a very verbose way to surface diff noise.
    class ConsoleDashboard
      def render(crew:, diffs:, telemetry:)
        puts '== Console Dashboard =='
        render_crew(crew)
        render_diffs(diffs)
        render_telemetry(telemetry)
      end

      private

      def render_crew(crew)
        crew.each do |role, members|
          puts "Role: #{role}"
          members.take(3).each do |member|
            puts "  - #{member.name} (#{member.certifications.join(', ')})"
          end
        end
      end

      def render_diffs(diffs)
        puts "\nDetected diffs:"
        diffs.to_a.first(3).each do |path, snippets|
          puts "- #{path}"
          [:added, :removed].each do |type|
            Array(snippets[type]).take(3).each do |entry|
              marker = type == :added ? '+' : '-'
              puts "    #{marker} #{entry[:payload]}"
            end
          end
        end
      end

      def render_telemetry(telemetry)
        puts "\nTelemetry:"
        telemetry.each do |stream, entries|
          puts "Stream: #{stream}"
          Array(entries).take(3).each do |entry|
            puts "  Ship: #{entry[:ship]}"
            Array(entry[:metrics]).take(3).each do |metric|
              puts "    Destination: #{metric[:destination]} latency=#{metric[:latency]}"
            end
          end
        end
      end
    end
  end
end
