{ Simple Pascal program for MCR flow/omniscience DAP integration testing.

  Mirrors the C/Nim/Rust flow tests:
    a = 10, b = 32, sum = 42, doubled = 84, final_result = 94

  Breakpoint is set at the assignment of the function result line inside
  `calculate_sum`; the DAP test verifies that the listed locals are
  reported with the expected values. }

program pascal_flow_test;

function calculate_sum(a, b: integer): integer;
var
  sum_val: integer;
  doubled: integer;
  final_result: integer;
begin
  sum_val := a + b;
  doubled := sum_val * 2;
  final_result := doubled + 10;
  writeln('Sum: ', sum_val);
  writeln('Doubled: ', doubled);
  writeln('Final: ', final_result);
  calculate_sum := final_result;
end;

var
  x, y, result_val: integer;
begin
  x := 10;
  y := 32;
  result_val := calculate_sum(x, y);
  writeln('Result: ', result_val);
end.
