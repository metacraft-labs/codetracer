# simple_trivial_chain — Nim
# let a = 10; let b = a; let c = b — terminates at Literal.
proc main() =
  let a: int = 10
  let b: int = a
  let c: int = b
  echo c

main()
