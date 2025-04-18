#!/usr/bin/env ruby

require_relative '../lib/maze_solver'

print "starting ruby_maze_solver"
p "starting ruby_maze_solver"

# A small obstacle course for smoke testing
smoke_test_grid = [
  [0, 1, 0],
  [0, 1, 0],
  [0, 0, 0]
]

smoke_test_start = MazeSolver::Point.new(0, 0)
smoke_test_endPoint = MazeSolver::Point.new(2, 2)

maze = MazeSolver::Maze.new(smoke_test_grid, smoke_test_start, smoke_test_endPoint)
path = maze.a_star_search
maze.visualize_path(path)

# change target to top right corner for next run

smoke_test_start = MazeSolver::Point.new(0, 0)
smoke_test_endPoint = MazeSolver::Point.new(0, 2)

maze = MazeSolver::Maze.new(smoke_test_grid, smoke_test_start, smoke_test_endPoint)
path = maze.a_star_search
maze.visualize_path(path)

print "end of ruby_maze_solver"
p "end of ruby_maze_solver"