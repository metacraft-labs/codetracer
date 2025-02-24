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
  var testBoards: array[10, Board] = [
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
     [0,0,0,0,0,0,0,0,0]]
  ]

  for i in 0..<10:
    echo "Test Sudoku #", i+1, " (Before):"
    printBoard(testBoards[i])
    if solveSudoku(testBoards[i]):
      echo "Solved Sudoku #", i+1, ":"
      printBoard(testBoards[i])
    else:
      echo "No solution found for Sudoku #", i+1, "."
    echo("-----------------------------------------")
