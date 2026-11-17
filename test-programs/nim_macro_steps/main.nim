# A program whose code runs through a macro and a template: what the editor's
# Toggle Macro Expansion expands inline, and what stepping walks through.
import std/macros

macro addTwice(target: untyped; amount: int): untyped =
  result = newStmtList()
  result.add quote do:
    `target` += `amount`
  result.add quote do:
    `target` += `amount`

template logValue(label: string; value: int) =
  echo label, " ", value

proc main() =
  var counter = 0
  addTwice(counter, 3)
  logValue("counter", counter)
  addTwice(counter, 5)
  logValue("counter", counter)

main()
