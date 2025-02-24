#!/usr/bin/env ruby

require_relative '../lib/maze_solver'

print "starting ruby_maze_solver"
p "starting ruby_maze_solver"

GRID_COUNT = 24 * 120 #24 frames per second
GRID_HEIGHT = 2160
GRID_WIDTH = 3840
# TODO: adjust obstacle count
OBSTACLE_COUNT = 1000  # Number of obstacles per grid


# Seed the random number generator for reproducibility
srand(1234)  # You can use any integer as the seed

def generate_random_grid(hight, width, obstacle_count)
  grid = Array.new(hight) { Array.new(width, 0) }
  obstacle_count.times do
    x = rand(hight)
    y = rand(width)
    grid[x][y] = 1
  end
  grid
end

# Create an array of random grids
grids = Array.new(GRID_COUNT) { generate_random_grid(GRID_HEIGHT, GRID_WIDTH , OBSTACLE_COUNT) }

# Define start and end points for all grids
start = MazeSolver::Point.new(0, 0)
end_point = MazeSolver::Point.new(GRID_HEIGHT - 1, GRID_WIDTH - 1)

# Solve each maze and visualize the solution
grids.each_with_index do |grid, index|
  # Ensure the start and end points are not blocked
  grid[start.x][start.y] = 0
  grid[end_point.x][end_point.y] = 0

  # Create the maze and solve it
  maze = MazeSolver::Maze.new(grid, start, end_point)
  path = maze.a_star_search

  puts "Maze ##{index + 1} solution:"
  maze.visualize_path(path)
  puts
end

print "end of ruby_maze_solver"
p "end of ruby_maze_solver"