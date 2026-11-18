{ A Pascal program whose main block has loops after a function that has one.

  The parser numbers the loops it meets in a function from 1 and restarts at
  each function node. A Pascal program's main block is not a function node, so
  its two loops continue `count_up`'s count (2 and 3), while main's flow holds
  only its own two loops. The flow must name each loop by its place among the
  loops it sends.

  The body mentions `grid` on each of its 100 passes, so the flow must send a
  bounded preview of the array, not the whole of it on every pass. }

program pascal_loop_flow_test;

function count_up(n: integer): integer;
var
  i, total: integer;
begin
  total := 0;
  for i := 1 to n do
    total := total + i;
  count_up := total;
end;

var
  r, c: integer;
  grid: array[0..9, 0..9] of integer;
begin
  for r := 0 to 9 do
    for c := 0 to 9 do
      grid[r][c] := r * 10 + c;
  writeln('Last: ', grid[9][9], ' Sum: ', count_up(4));
end.
