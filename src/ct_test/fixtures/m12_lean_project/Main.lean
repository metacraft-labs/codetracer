def add (a b : Nat) : Nat := a + b

def main : IO Unit := do
  if add 2 3 == 5 then
    IO.println "lean fixture passed"
  else
    throw <| IO.userError "lean fixture failed"
