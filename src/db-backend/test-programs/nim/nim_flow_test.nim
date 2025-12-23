# Simple Nim program for flow/omniscience integration testing
# This program tests that local variables inside procs can be loaded
# without name mangling (unlike module-level globals which ARE mangled).

proc calculateSum(a: int, b: int): int =
  # Local variables inside a proc - these should NOT be mangled
  let sum = a + b
  let doubled = sum * 2
  let final = doubled + 10
  echo "Sum: ", sum
  echo "Doubled: ", doubled
  echo "Final: ", final
  return final

proc main() =
  # Local variables in main proc
  let x = 10
  let y = 32
  let result = calculateSum(x, y)
  echo "Result: ", result

# Call main
main()
