# implicit_result — Nim
# Nim procs that declare a return type get an implicit ``result`` variable.
# Writes to ``result`` (or a bare last expression) chain through to the
# call-site binding.  The origin walker must hop from the caller's ``c``
# into the proc, terminate at the literal ``42`` that the proc assigns
# into ``result``.
proc compute(): int =
  result = 42

proc main() =
  let c: int = compute()
  echo c

main()
