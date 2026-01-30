module MazeSolver
    class PriorityQueue
      def initialize
        @elements = []
      end

      def empty?
        @elements.empty?
      end

      def put(element, priority)
        @elements << [priority, element]
        @elements.sort_by!(&:first)
      end

      def get
        @elements.shift.last
      end
    end
  end
