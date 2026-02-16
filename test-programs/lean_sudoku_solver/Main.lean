/-
  Sudoku solver using backtracking.
  Built with: lake build
  Produces DWARF debug info for codetracer RR-based tracing.
-/

def SIZE : Nat := 9

/-- A sudoku board is a 9x9 array of natural numbers (0 = empty). -/
abbrev Board := Array (Array Nat)

def printBoard (board : Board) : IO Unit := do
  for row in board do
    for cell in row do
      if cell == 0 then
        IO.print ". "
      else
        IO.print s!"{cell} "
    IO.println ""

def isValid (board : Board) (row col num : Nat) : Bool := Id.run do
  -- Check row
  for c in [:SIZE] do
    if board[row]![c]! == num then return false
  -- Check column
  for r in [:SIZE] do
    if board[r]![col]! == num then return false
  -- Check 3x3 box
  let boxRowStart := (row / 3) * 3
  let boxColStart := (col / 3) * 3
  for r in [boxRowStart:boxRowStart + 3] do
    for c in [boxColStart:boxColStart + 3] do
      if board[r]![c]! == num then return false
  return true

def findEmptyCell (board : Board) : Option (Nat × Nat) := Id.run do
  for r in [:SIZE] do
    for c in [:SIZE] do
      if board[r]![c]! == 0 then return some (r, c)
  return none

partial def solve (board : Board) : Option Board := Id.run do
  match findEmptyCell board with
  | none => return some board  -- No empty cell means solved
  | some (row, col) =>
    for num in [1, 2, 3, 4, 5, 6, 7, 8, 9] do
      if isValid board row col num then
        let newBoard := board.set! row (board[row]!.set! col num)
        match solve newBoard with
        | some solved => return some solved
        | none => pure ()
    return none

def mkBoard (rows : List (List Nat)) : Board :=
  rows.toArray.map (·.toArray)

def main : IO Unit := do
  let testBoards : Array Board := #[
    -- Example 1
    mkBoard [[5,3,0,0,7,0,0,0,0],
             [6,0,0,1,9,5,0,0,0],
             [0,9,8,0,0,0,0,6,0],
             [8,0,0,0,6,0,0,0,3],
             [4,0,0,8,0,3,0,0,1],
             [7,0,0,0,2,0,0,0,6],
             [0,6,0,0,0,0,2,8,0],
             [0,0,0,4,1,9,0,0,5],
             [0,0,0,0,8,0,0,7,9]],
    -- Example 2
    mkBoard [[0,0,0,0,0,0,0,0,0],
             [0,0,0,0,0,3,0,8,5],
             [0,0,1,0,2,0,0,0,0],
             [0,0,0,0,0,0,0,0,7],
             [0,0,0,0,1,0,0,0,0],
             [3,0,0,0,0,0,0,0,0],
             [0,0,0,0,4,0,1,0,0],
             [5,7,0,0,0,0,0,0,0],
             [0,0,0,0,0,0,0,0,0]],
    -- Example 3
    mkBoard [[1,0,0,0,0,7,0,9,0],
             [0,3,0,0,2,0,0,0,8],
             [0,0,9,6,0,0,5,0,0],
             [0,0,5,3,0,0,9,0,0],
             [0,1,0,0,0,0,0,0,2],
             [0,0,6,0,0,3,0,0,0],
             [0,6,0,0,0,0,0,0,0],
             [0,0,0,0,0,0,0,0,0],
             [0,0,0,0,0,0,0,0,0]],
    -- Example 4
    mkBoard [[0,0,0,2,6,0,7,0,1],
             [6,8,0,0,7,0,0,9,0],
             [1,9,0,0,0,4,5,0,0],
             [8,2,0,1,0,0,0,4,0],
             [0,0,4,6,0,2,9,0,0],
             [0,5,0,0,0,3,0,2,8],
             [0,0,9,3,0,0,0,7,4],
             [0,4,0,0,5,0,0,3,6],
             [7,0,3,0,1,8,0,0,0]],
    -- Example 5
    mkBoard [[0,0,0,0,0,0,0,0,0],
             [0,0,0,0,0,3,0,8,5],
             [0,0,1,0,2,0,0,0,0],
             [0,0,0,0,0,0,0,0,7],
             [0,0,0,0,1,0,0,0,0],
             [3,0,0,0,0,0,0,0,0],
             [0,0,0,0,4,0,1,0,0],
             [5,7,0,0,0,0,0,0,0],
             [0,0,0,0,0,0,0,0,0]],
    -- Example 6
    mkBoard [[0,0,0,0,0,0,0,0,6],
             [0,0,0,0,0,3,0,0,0],
             [0,0,1,0,2,0,0,0,0],
             [0,0,0,0,6,0,0,0,3],
             [4,0,0,8,0,3,0,0,1],
             [7,0,0,0,2,0,0,0,6],
             [0,6,0,0,0,0,2,8,0],
             [0,0,0,4,1,9,0,0,5],
             [0,0,0,0,8,0,0,7,9]],
    -- Example 7
    mkBoard [[9,0,0,0,0,0,0,0,5],
             [0,1,0,0,0,5,0,0,0],
             [0,0,0,3,0,0,0,8,0],
             [0,0,0,0,0,6,0,0,0],
             [0,0,0,0,0,0,2,0,0],
             [3,0,7,0,0,0,0,0,1],
             [0,6,0,0,0,0,0,9,0],
             [0,0,0,4,0,0,0,0,0],
             [0,0,0,0,0,0,0,0,0]],
    -- Example 8
    mkBoard [[2,0,0,0,0,0,0,0,0],
             [0,0,0,0,0,3,0,8,5],
             [0,0,1,0,2,0,0,0,0],
             [0,0,0,0,0,0,0,0,7],
             [0,0,0,0,1,0,0,0,0],
             [3,0,0,0,0,0,0,0,0],
             [0,0,0,0,4,0,1,0,0],
             [5,7,0,0,0,0,0,0,0],
             [0,0,0,0,0,0,0,0,0]],
    -- Example 9
    mkBoard [[0,0,0,0,7,0,0,0,0],
             [6,0,0,1,9,5,0,0,0],
             [0,9,8,0,0,0,0,6,0],
             [8,0,0,0,6,0,0,0,3],
             [4,0,0,8,0,3,0,0,1],
             [7,0,0,0,2,0,0,0,6],
             [0,6,0,0,0,0,2,8,0],
             [0,0,0,4,1,9,0,0,5],
             [0,0,0,0,8,0,0,7,0]],
    -- Example 10
    mkBoard [[0,0,0,4,0,0,0,0,0],
             [0,0,0,0,0,3,0,8,5],
             [0,2,1,0,0,0,0,0,0],
             [0,0,0,0,0,0,0,0,7],
             [0,0,0,0,1,0,0,0,0],
             [3,0,0,0,0,0,0,0,0],
             [0,0,0,0,4,0,1,0,0],
             [5,7,0,0,0,0,0,0,0],
             [0,0,0,0,0,0,0,0,0]]
  ]

  for i in [:testBoards.size] do
    let board := testBoards[i]!
    IO.println s!"Test Sudoku #{i + 1} (Before):"
    printBoard board
    match solve board with
    | some solved =>
      IO.println s!"Solved Sudoku #{i + 1}:"
      printBoard solved
    | none =>
      IO.println s!"No solution found for Sudoku #{i + 1}."
    IO.println "-----------------------------------------"
