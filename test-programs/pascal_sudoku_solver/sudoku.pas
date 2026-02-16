{ Sudoku solver using backtracking.
  Compiled with: fpc -glw3 sudoku.pas
  Produces DWARF debug info for codetracer RR-based tracing. }
program sudoku;

const
  SIZE = 9;

type
  TBoard = array[0..SIZE-1, 0..SIZE-1] of Byte;

procedure PrintBoard(var board: TBoard);
var
  r, c: Integer;
begin
  for r := 0 to SIZE - 1 do
  begin
    for c := 0 to SIZE - 1 do
    begin
      if board[r][c] = 0 then
        Write('. ')
      else
        Write(board[r][c], ' ');
    end;
    WriteLn;
  end;
end;

function IsValid(var board: TBoard; row, col: Integer; num: Byte): Boolean;
var
  r, c: Integer;
  boxRowStart, boxColStart: Integer;
begin
  { Check row }
  for c := 0 to SIZE - 1 do
    if board[row][c] = num then
      Exit(False);

  { Check column }
  for r := 0 to SIZE - 1 do
    if board[r][col] = num then
      Exit(False);

  { Check 3x3 box }
  boxRowStart := (row div 3) * 3;
  boxColStart := (col div 3) * 3;
  for r := boxRowStart to boxRowStart + 2 do
    for c := boxColStart to boxColStart + 2 do
      if board[r][c] = num then
        Exit(False);

  IsValid := True;
end;

function FindEmptyCell(var board: TBoard; var row, col: Integer): Boolean;
var
  r, c: Integer;
begin
  for r := 0 to SIZE - 1 do
    for c := 0 to SIZE - 1 do
      if board[r][c] = 0 then
      begin
        row := r;
        col := c;
        Exit(True);
      end;
  FindEmptyCell := False;
end;

function Solve(var board: TBoard): Boolean;
var
  row, col: Integer;
  num: Byte;
begin
  if not FindEmptyCell(board, row, col) then
    Exit(True); { No empty cell means solved }

  for num := 1 to 9 do
  begin
    if IsValid(board, row, col, num) then
    begin
      board[row][col] := num;
      if Solve(board) then
        Exit(True);
      board[row][col] := 0; { backtrack }
    end;
  end;
  Solve := False;
end;

var
  boards: array[0..9] of TBoard;
  i, r, c: Integer;

begin
  { Initialize all boards to zero }
  for i := 0 to 9 do
    for r := 0 to SIZE - 1 do
      for c := 0 to SIZE - 1 do
        boards[i][r][c] := 0;

  { Example 1 }
  boards[0][0][0]:=5; boards[0][0][1]:=3; boards[0][0][4]:=7;
  boards[0][1][0]:=6; boards[0][1][3]:=1; boards[0][1][4]:=9; boards[0][1][5]:=5;
  boards[0][2][1]:=9; boards[0][2][2]:=8; boards[0][2][7]:=6;
  boards[0][3][0]:=8; boards[0][3][4]:=6; boards[0][3][8]:=3;
  boards[0][4][0]:=4; boards[0][4][3]:=8; boards[0][4][5]:=3; boards[0][4][8]:=1;
  boards[0][5][0]:=7; boards[0][5][4]:=2; boards[0][5][8]:=6;
  boards[0][6][1]:=6; boards[0][6][6]:=2; boards[0][6][7]:=8;
  boards[0][7][3]:=4; boards[0][7][4]:=1; boards[0][7][5]:=9; boards[0][7][8]:=5;
  boards[0][8][4]:=8; boards[0][8][7]:=7; boards[0][8][8]:=9;

  { Example 2 }
  boards[1][1][5]:=3; boards[1][1][7]:=8; boards[1][1][8]:=5;
  boards[1][2][2]:=1; boards[1][2][4]:=2;
  boards[1][3][8]:=7;
  boards[1][4][4]:=1;
  boards[1][5][0]:=3;
  boards[1][6][4]:=4; boards[1][6][6]:=1;
  boards[1][7][0]:=5; boards[1][7][1]:=7;

  { Example 3 }
  boards[2][0][0]:=1; boards[2][0][5]:=7; boards[2][0][7]:=9;
  boards[2][1][1]:=3; boards[2][1][4]:=2; boards[2][1][8]:=8;
  boards[2][2][2]:=9; boards[2][2][3]:=6; boards[2][2][6]:=5;
  boards[2][3][2]:=5; boards[2][3][3]:=3; boards[2][3][6]:=9;
  boards[2][4][1]:=1; boards[2][4][8]:=2;
  boards[2][5][2]:=6; boards[2][5][5]:=3;
  boards[2][6][1]:=6;

  { Example 4 }
  boards[3][0][3]:=2; boards[3][0][4]:=6; boards[3][0][6]:=7; boards[3][0][8]:=1;
  boards[3][1][0]:=6; boards[3][1][1]:=8; boards[3][1][4]:=7; boards[3][1][7]:=9;
  boards[3][2][0]:=1; boards[3][2][1]:=9; boards[3][2][5]:=4; boards[3][2][6]:=5;
  boards[3][3][0]:=8; boards[3][3][1]:=2; boards[3][3][3]:=1; boards[3][3][7]:=4;
  boards[3][4][2]:=4; boards[3][4][3]:=6; boards[3][4][5]:=2; boards[3][4][6]:=9;
  boards[3][5][1]:=5; boards[3][5][5]:=3; boards[3][5][7]:=2; boards[3][5][8]:=8;
  boards[3][6][2]:=9; boards[3][6][3]:=3; boards[3][6][7]:=7; boards[3][6][8]:=4;
  boards[3][7][1]:=4; boards[3][7][4]:=5; boards[3][7][7]:=3; boards[3][7][8]:=6;
  boards[3][8][0]:=7; boards[3][8][2]:=3; boards[3][8][4]:=1; boards[3][8][5]:=8;

  { Examples 5-10: same as C version (sparse boards for variety) }
  { Example 5 = same as Example 2 }
  boards[4] := boards[1];

  { Example 6 }
  boards[5][0][8]:=6;
  boards[5][1][5]:=3;
  boards[5][2][2]:=1; boards[5][2][4]:=2;
  boards[5][3][4]:=6; boards[5][3][8]:=3;
  boards[5][4][0]:=4; boards[5][4][3]:=8; boards[5][4][5]:=3; boards[5][4][8]:=1;
  boards[5][5][0]:=7; boards[5][5][4]:=2; boards[5][5][8]:=6;
  boards[5][6][1]:=6; boards[5][6][6]:=2; boards[5][6][7]:=8;
  boards[5][7][3]:=4; boards[5][7][4]:=1; boards[5][7][5]:=9; boards[5][7][8]:=5;
  boards[5][8][4]:=8; boards[5][8][7]:=7; boards[5][8][8]:=9;

  { Example 7 }
  boards[6][0][0]:=9; boards[6][0][8]:=5;
  boards[6][1][1]:=1; boards[6][1][5]:=5;
  boards[6][2][3]:=3; boards[6][2][7]:=8;
  boards[6][3][5]:=6;
  boards[6][4][6]:=2;
  boards[6][5][0]:=3; boards[6][5][2]:=7; boards[6][5][8]:=1;
  boards[6][6][1]:=6; boards[6][6][7]:=9;
  boards[6][7][3]:=4;

  { Example 8 }
  boards[7][0][0]:=2;
  boards[7][1][5]:=3; boards[7][1][7]:=8; boards[7][1][8]:=5;
  boards[7][2][2]:=1; boards[7][2][4]:=2;
  boards[7][3][8]:=7;
  boards[7][4][4]:=1;
  boards[7][5][0]:=3;
  boards[7][6][4]:=4; boards[7][6][6]:=1;
  boards[7][7][0]:=5; boards[7][7][1]:=7;

  { Example 9 }
  boards[8][0][4]:=7;
  boards[8][1][0]:=6; boards[8][1][3]:=1; boards[8][1][4]:=9; boards[8][1][5]:=5;
  boards[8][2][1]:=9; boards[8][2][2]:=8; boards[8][2][7]:=6;
  boards[8][3][0]:=8; boards[8][3][4]:=6; boards[8][3][8]:=3;
  boards[8][4][0]:=4; boards[8][4][3]:=8; boards[8][4][5]:=3; boards[8][4][8]:=1;
  boards[8][5][0]:=7; boards[8][5][4]:=2; boards[8][5][8]:=6;
  boards[8][6][1]:=6; boards[8][6][6]:=2; boards[8][6][7]:=8;
  boards[8][7][3]:=4; boards[8][7][4]:=1; boards[8][7][5]:=9; boards[8][7][8]:=5;
  boards[8][8][7]:=7;

  { Example 10 }
  boards[9][0][3]:=4;
  boards[9][1][5]:=3; boards[9][1][7]:=8; boards[9][1][8]:=5;
  boards[9][2][1]:=2; boards[9][2][2]:=1;
  boards[9][3][8]:=7;
  boards[9][4][4]:=1;
  boards[9][5][0]:=3;
  boards[9][6][4]:=4; boards[9][6][6]:=1;
  boards[9][7][0]:=5; boards[9][7][1]:=7;

  for i := 0 to 9 do
  begin
    WriteLn('Test Sudoku #', i + 1, ' (Before):');
    PrintBoard(boards[i]);
    if Solve(boards[i]) then
    begin
      WriteLn('Solved Sudoku #', i + 1, ':');
      PrintBoard(boards[i]);
    end
    else
      WriteLn('No solution found for Sudoku #', i + 1, '.');
    WriteLn('-----------------------------------------');
  end;
end.
