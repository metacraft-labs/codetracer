# P4 GUI-ops latency fixture (Nim).  Mirrors fixtures/gui-ops/python/main.py.
proc fold(x, y: int): int =
  x * 31 + y

proc main() =
  let a: int = 1
  let b: int = a + 2
  let c: int = b * 3
  let d: int = c + 10
  let e: int = fold(d, 7)
  echo e

main()
