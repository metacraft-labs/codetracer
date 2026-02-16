# Sudoku solver using backtracking.
# Compiled with: crystal build --debug sudoku.cr
# Produces DWARF debug info for codetracer RR-based tracing.

SIZE = 9

def print_board(board : Array(Array(Int32)))
  board.each do |row|
    row.each do |cell|
      if cell == 0
        print ". "
      else
        print "#{cell} "
      end
    end
    puts
  end
end

def is_valid(board : Array(Array(Int32)), row : Int32, col : Int32, num : Int32) : Bool
  # Check row
  SIZE.times do |c|
    return false if board[row][c] == num
  end

  # Check column
  SIZE.times do |r|
    return false if board[r][col] == num
  end

  # Check 3x3 box
  box_row_start = (row // 3) * 3
  box_col_start = (col // 3) * 3
  3.times do |dr|
    3.times do |dc|
      return false if board[box_row_start + dr][box_col_start + dc] == num
    end
  end

  true
end

def find_empty_cell(board : Array(Array(Int32))) : {Int32, Int32}?
  SIZE.times do |r|
    SIZE.times do |c|
      if board[r][c] == 0
        return {r.to_i32, c.to_i32}
      end
    end
  end
  nil
end

def solve(board : Array(Array(Int32))) : Bool
  cell = find_empty_cell(board)
  return true if cell.nil? # No empty cell means solved

  row, col = cell

  (1..9).each do |num|
    n = num.to_i32
    if is_valid(board, row, col, n)
      board[row][col] = n
      return true if solve(board)
      board[row][col] = 0_i32 # backtrack
    end
  end
  false
end

# 10 test boards, same puzzles as the C version
test_boards = [
  # Example 1
  [[5,3,0,0,7,0,0,0,0],
   [6,0,0,1,9,5,0,0,0],
   [0,9,8,0,0,0,0,6,0],
   [8,0,0,0,6,0,0,0,3],
   [4,0,0,8,0,3,0,0,1],
   [7,0,0,0,2,0,0,0,6],
   [0,6,0,0,0,0,2,8,0],
   [0,0,0,4,1,9,0,0,5],
   [0,0,0,0,8,0,0,7,9]],
  # Example 2
  [[0,0,0,0,0,0,0,0,0],
   [0,0,0,0,0,3,0,8,5],
   [0,0,1,0,2,0,0,0,0],
   [0,0,0,0,0,0,0,0,7],
   [0,0,0,0,1,0,0,0,0],
   [3,0,0,0,0,0,0,0,0],
   [0,0,0,0,4,0,1,0,0],
   [5,7,0,0,0,0,0,0,0],
   [0,0,0,0,0,0,0,0,0]],
  # Example 3
  [[1,0,0,0,0,7,0,9,0],
   [0,3,0,0,2,0,0,0,8],
   [0,0,9,6,0,0,5,0,0],
   [0,0,5,3,0,0,9,0,0],
   [0,1,0,0,0,0,0,0,2],
   [0,0,6,0,0,3,0,0,0],
   [0,6,0,0,0,0,0,0,0],
   [0,0,0,0,0,0,0,0,0],
   [0,0,0,0,0,0,0,0,0]],
  # Example 4
  [[0,0,0,2,6,0,7,0,1],
   [6,8,0,0,7,0,0,9,0],
   [1,9,0,0,0,4,5,0,0],
   [8,2,0,1,0,0,0,4,0],
   [0,0,4,6,0,2,9,0,0],
   [0,5,0,0,0,3,0,2,8],
   [0,0,9,3,0,0,0,7,4],
   [0,4,0,0,5,0,0,3,6],
   [7,0,3,0,1,8,0,0,0]],
  # Example 5
  [[0,0,0,0,0,0,0,0,0],
   [0,0,0,0,0,3,0,8,5],
   [0,0,1,0,2,0,0,0,0],
   [0,0,0,0,0,0,0,0,7],
   [0,0,0,0,1,0,0,0,0],
   [3,0,0,0,0,0,0,0,0],
   [0,0,0,0,4,0,1,0,0],
   [5,7,0,0,0,0,0,0,0],
   [0,0,0,0,0,0,0,0,0]],
  # Example 6
  [[0,0,0,0,0,0,0,0,6],
   [0,0,0,0,0,3,0,0,0],
   [0,0,1,0,2,0,0,0,0],
   [0,0,0,0,6,0,0,0,3],
   [4,0,0,8,0,3,0,0,1],
   [7,0,0,0,2,0,0,0,6],
   [0,6,0,0,0,0,2,8,0],
   [0,0,0,4,1,9,0,0,5],
   [0,0,0,0,8,0,0,7,9]],
  # Example 7
  [[9,0,0,0,0,0,0,0,5],
   [0,1,0,0,0,5,0,0,0],
   [0,0,0,3,0,0,0,8,0],
   [0,0,0,0,0,6,0,0,0],
   [0,0,0,0,0,0,2,0,0],
   [3,0,7,0,0,0,0,0,1],
   [0,6,0,0,0,0,0,9,0],
   [0,0,0,4,0,0,0,0,0],
   [0,0,0,0,0,0,0,0,0]],
  # Example 8
  [[2,0,0,0,0,0,0,0,0],
   [0,0,0,0,0,3,0,8,5],
   [0,0,1,0,2,0,0,0,0],
   [0,0,0,0,0,0,0,0,7],
   [0,0,0,0,1,0,0,0,0],
   [3,0,0,0,0,0,0,0,0],
   [0,0,0,0,4,0,1,0,0],
   [5,7,0,0,0,0,0,0,0],
   [0,0,0,0,0,0,0,0,0]],
  # Example 9
  [[0,0,0,0,7,0,0,0,0],
   [6,0,0,1,9,5,0,0,0],
   [0,9,8,0,0,0,0,6,0],
   [8,0,0,0,6,0,0,0,3],
   [4,0,0,8,0,3,0,0,1],
   [7,0,0,0,2,0,0,0,6],
   [0,6,0,0,0,0,2,8,0],
   [0,0,0,4,1,9,0,0,5],
   [0,0,0,0,8,0,0,7,0]],
  # Example 10
  [[0,0,0,4,0,0,0,0,0],
   [0,0,0,0,0,3,0,8,5],
   [0,2,1,0,0,0,0,0,0],
   [0,0,0,0,0,0,0,0,7],
   [0,0,0,0,1,0,0,0,0],
   [3,0,0,0,0,0,0,0,0],
   [0,0,0,0,4,0,1,0,0],
   [5,7,0,0,0,0,0,0,0],
   [0,0,0,0,0,0,0,0,0]],
] of Array(Array(Int32))

test_boards.each_with_index do |board, i|
  # Deep copy so we don't mutate the original when printing "Before"
  work = board.map(&.dup)
  puts "Test Sudoku ##{i + 1} (Before):"
  print_board(work)
  if solve(work)
    puts "Solved Sudoku ##{i + 1}:"
    print_board(work)
  else
    puts "No solution found for Sudoku ##{i + 1}."
  end
  puts "-----------------------------------------"
end
