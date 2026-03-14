-- Simple Lean program for flow/omniscience integration testing.
-- Lean compiles to C, so DWARF debug info refers to generated C files,
-- not .lean source. This program is used primarily for build+record
-- pipeline verification and basic DAP replay tests.

def calculateSum (a : Nat) (b : Nat) : Nat :=
  let sum := a + b
  let doubled := sum * 2
  let final_ := doubled + 10
  final_

def main : IO Unit := do
  let x := 10
  let y := 32
  let result := calculateSum x y
  IO.println s!"Sum result: {result}"
