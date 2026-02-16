const SIZE = 9

type
  Board = array[SIZE, array[SIZE, uint8]]

proc printBoard(board: Board) =
  for r in 0..<SIZE:
    for c in 0..<SIZE:
      if board[r][c] == 0:
        stdout.write(". ")
      else:
        stdout.write($board[r][c] & " ")
    stdout.writeLine("")

proc isValid(board: Board, row, col: int, num: uint8): bool =
  # Check row
  for c in 0..<SIZE:
    if board[row][c] == num:
      return false
  # Check column
  for r in 0..<SIZE:
    if board[r][col] == num:
      return false
  # Check 3x3 box
  let boxRowStart = (row div 3) * 3
  let boxColStart = (col div 3) * 3
  for r in boxRowStart..<boxRowStart+3:
    for c in boxColStart..<boxColStart+3:
      if board[r][c] == num:
        return false
  return true

proc findEmptyCell(board: Board, row, col: var int): bool =
  for r in 0..<SIZE:
    for c in 0..<SIZE:
      if board[r][c] == 0:
        row = r
        col = c
        return true
  return false

proc solveSudoku(board: var Board): bool =
  var row, col: int
  if not findEmptyCell(board, row, col):
    return true # solved

  for num in 1..9:
    if isValid(board, row, col, uint8(num)):
      board[row][col] = uint8(num)
      if solveSudoku(board):
        return true
      board[row][col] = 0 # backtrack

  return false

when isMainModule:
  # Use a nearly-solved board (only 3 empty cells) to keep the RR trace small.
  # Full 41-empty-cell puzzles produce massive traces that are slow to replay
  # and may exceed the Electron frontend's memory limits.
  var testBoards: array[1, Board] = [
    [[5,3,4,6,7,8,9,1,2],
     [6,7,2,1,9,5,3,4,8],
     [1,9,8,3,4,2,5,6,7],
     [8,5,9,7,6,1,4,2,3],
     [4,2,6,8,5,3,7,9,1],
     [7,1,3,9,2,4,8,5,6],
     [9,6,1,5,3,7,2,8,4],
     [2,8,7,4,1,9,6,3,5],
     [3,4,5,0,8,0,0,7,9]]
  ]

  for i in 0..<1:
    echo "Test Sudoku #", i+1, " (Before):"
    printBoard(testBoards[i])
    if solveSudoku(testBoards[i]):
      echo "Solved Sudoku #", i+1, ":"
      printBoard(testBoards[i])
    else:
      echo "No solution found for Sudoku #", i+1, "."
    echo("-----------------------------------------")
