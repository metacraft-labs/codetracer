# The project `shared_editor_lsp_chromium_test.nim` opens in a real Nim
# language server: a proc to hover and jump to, an object to complete.

type
  Greeter = object
    name: string
    times: int

proc greet(g: Greeter): string =
  ## Says hello.
  result = "hello " & g.name

let greeter = Greeter(name: "world", times: 2)
echo greet(greeter)
echo greeter.name
