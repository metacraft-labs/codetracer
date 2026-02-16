class SudokuSolver
  SIZE = 9

  def initialize(board)
    @board = board
  end

  def solve
    row, col = find_empty_cell
    return true if row.nil? # No empty cell means solved

    (1..9).each do |num|
      if valid?(num, row, col)
        @board[row][col] = num
        return true if solve
        @board[row][col] = 0 # backtrack
      end
    end
    false
  end

  def print_board
    @board.each do |row|
      puts row.map { |val| val == 0 ? '.' : val }.join(' ')
    end
  end

  private

  def find_empty_cell
    (0...SIZE).each do |r|
      (0...SIZE).each do |c|
        return [r, c] if @board[r][c] == 0
      end
    end
    nil
  end

  def valid?(num, row, col)
    # Check row
    return false if @board[row].include?(num)
    # Check column
    return false if @board.transpose[col].include?(num)
    # Check 3x3 grid
    box_row_start = (row / 3) * 3
    box_col_start = (col / 3) * 3
    (box_row_start...(box_row_start+3)).each do |r|
      (box_col_start...(box_col_start+3)).each do |c|
        return false if @board[r][c] == num
      end
    end
    true
  end
end

# Use a nearly-solved board (only 3 empty cells) to keep the DB trace small.
# A full 41-empty-cell puzzle produces >250 MB of trace data via the Ruby
# recorder, which the Electron frontend cannot load within the test timeout.
test_boards = [
  [
    [5,3,4,6,7,8,9,1,2],
    [6,7,2,1,9,5,3,4,8],
    [1,9,8,3,4,2,5,6,7],
    [8,5,9,7,6,1,4,2,3],
    [4,2,6,8,5,3,7,9,1],
    [7,1,3,9,2,4,8,5,6],
    [9,6,1,5,3,7,2,8,4],
    [2,8,7,4,1,9,6,3,5],
    [3,4,5,0,8,0,0,7,9]
  ]
]

test_boards.each_with_index do |board, i|
  puts "Test Sudoku ##{i+1} (Before):"
  solver = SudokuSolver.new(board)
  solver.print_board
  if solver.solve
    puts "Solved Sudoku ##{i+1}:"
    solver.print_board
  else
    puts "No solution found for Sudoku ##{i+1}."
  end
  puts "-----------------------------------------"
end
