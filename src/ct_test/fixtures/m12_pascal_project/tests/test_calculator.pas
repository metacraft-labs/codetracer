program TestCalculator;

function Add(a, b: integer): integer;
begin
  Add := a + b;
end;

begin
  if Add(2, 3) <> 5 then
    halt(1);
  writeln('pascal fixture passed');
end.
