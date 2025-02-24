module MazeSolver
    class Point
      attr_accessor :x, :y
  
      def initialize(x, y)
        @x = x
        @y = y
      end
  
      def ==(other)
        @x == other.x && @y == other.y
      end
  
      def to_s
        "(#{@x}, #{@y})"
      end
  
      def hash
        [@x, @y].hash
      end
  
      alias eql? ==
    end
  end