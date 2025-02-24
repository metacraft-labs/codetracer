require 'set'
require_relative 'point'
require_relative 'priority_queue'

module MazeSolver
  class Maze
    attr_accessor :grid, :start, :end

    def initialize(grid, start_point, end_point)
      @grid = grid
      @start = start_point
      @end = end_point
    end

    def neighbors(point)
      directions = [
        [0, 1],  # Right
        [1, 0],  # Down
        [0, -1], # Left
        [-1, 0]  # Up
      ]
      neighbors = directions.map do |dx, dy|
        new_x = point.x + dx
        new_y = point.y + dy
        if new_x.between?(0, @grid.length - 1) && new_y.between?(0, @grid[0].length - 1) && @grid[new_x][new_y] != 1
          Point.new(new_x, new_y)
        end
      end
      neighbors.compact
    end

    def a_star_search
      frontier = PriorityQueue.new
      frontier.put(@start, 0)
      came_from = {}
      cost_so_far = {}
      came_from[@start] = nil
      cost_so_far[@start] = 0

      until frontier.empty?
        current = frontier.get

        break if current == @end

        neighbors(current).each do |next_point|
          new_cost = cost_so_far[current] + 1
          if !cost_so_far.key?(next_point) || new_cost < cost_so_far[next_point]
            cost_so_far[next_point] = new_cost
            priority = new_cost + heuristic(next_point, @end)
            frontier.put(next_point, priority)
            came_from[next_point] = current
          end
        end
      end

      reconstruct_path(came_from, @start, @end)
    end

    def visualize_path(path)
      path_points = path.map { |p| [p.x, p.y] }
      @grid.each_with_index do |row, x|
        row.each_with_index do |cell, y|
          if [x, y] == [@start.x, @start.y]
            p "S "
          elsif [x, y] == [@end.x, @end.y]
            p "E "
          elsif path_points.include?([x, y])
            p "* "
          else
            p cell == 1 ? "# " : ". "
          end
        end
        puts  
      end
    end

    private

    def heuristic(point1, point2)
      (point1.x - point2.x).abs + (point1.y - point2.y).abs
    end

    def reconstruct_path(came_from, start, goal)
      current = goal
      path = []
      while current != start
        path << current
        current = came_from[current]
      end
      path << start
      path.reverse
    end
  end
end
