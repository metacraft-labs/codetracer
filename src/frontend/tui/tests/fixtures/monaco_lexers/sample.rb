# A Ruby sample.
require 'set'

=begin
A block comment
across lines.
=end

module Geometry
  class Point
    attr_reader :x, :y
    ORIGIN = [0, 0].freeze

    def initialize(x = 0, y = 0)
      @x, @y = x, y
      @@count ||= 0
      @@count += 1
    end

    def to_s
      "(#{@x}, #{@y})"
    end

    def self.parse(text)
      if text =~ /\((\d+),\s*(\d+)\)/
        new($1.to_i, $2.to_i)
      else
        raise ArgumentError, 'bad point'
      end
    end
  end
end

points = %w[a b c].map.with_index { |name, i| Geometry::Point.new(i, i * 2) }
text = <<~HEREDOC
  Points: #{points.size}
  Hex: #{0x1F} Float: #{1.5e3}
HEREDOC
puts text unless points.empty?
symbols = %i[one two]
puts symbols.inspect, :done, nil.to_a.inspect
