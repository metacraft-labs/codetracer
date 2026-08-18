## Unit tests for the shared Nim lexical scanner (``ct_test/nim_lexer``).
##
## No mocks: every case runs the real scanner over real Nim source text.
## The cases are organised around the constructs that can *contain* a quote,
## an apostrophe or a ``#`` — the ones a naive scanner desynchronises on, and
## the reason this module exists.

import std/[sequtils, strutils, unittest]

import nim_lexer

proc kinds(source: string): seq[NimTokenKind] =
  scanNimSource(source).mapIt(it.kind)

proc texts(source: string): seq[string] =
  ## Exact source slices. Tokens carry offsets, not copies of their text, so
  ## the slice is taken here — see `NimToken`.
  scanNimSource(source).mapIt(source.sliceOf(it))

proc values(source: string): seq[string] =
  ## Decoded literal bodies (empty for non-literal kinds).
  scanNimSource(source).mapIt(it.value)

suite "ct-test Nim lexical scanner":
  test "a numeric type suffix belongs to the number token":
    # The defect this module was written for: the apostrophe in `10485760'i64`
    # is a type suffix, not the opening quote of a character literal.
    check kinds("10485760'i64") == @[ntkNumber]
    check texts("10485760'i64") == @["10485760'i64"]
    check texts("0'u8") == @["0'u8"]
    check texts("1_000_000'u32") == @["1_000_000'u32"]

  test "float and hexadecimal literals carry their suffixes too":
    check texts("1.0'f32") == @["1.0'f32"]
    check texts("2.5'f64") == @["2.5'f64"]
    # 'F' is a hex digit AND a float-suffix letter; the suffix starts at the
    # apostrophe, so the two cannot be confused.
    check texts("0x1F'i64") == @["0x1F'i64"]
    check texts("0b1010'u8") == @["0b1010'u8"]
    check texts("0o777'i16") == @["0o777'i16"]

  test "custom numeric literals are one token":
    check kinds("12'MyMeters") == @[ntkNumber]
    check texts("12'MyMeters") == @["12'MyMeters"]

  test "suffixes without an apostrophe are still part of the number":
    check texts("1u8") == @["1u8"]
    check texts("3.5f32") == @["3.5f32"]

  test "a dot only starts a fraction when a digit follows it":
    # `1..2` is a range, not a malformed float; consuming the dots into the
    # number would merge two statements' worth of source.
    check texts("1..2") == @["1", ".", ".", "2"]
    check texts("1.5e-3") == @["1.5e-3"]

  test "character literals are single tokens":
    check kinds("'a'") == @[ntkChar]
    check values("'a'") == @["a"]
    check texts(r"'\n'") == @[r"'\n'"]
    check texts(r"'\x41'") == @[r"'\x41'"]

  test "an escaped apostrophe does not end the character literal early":
    check kinds(r"'\''") == @[ntkChar]
    check texts(r"'\''") == @[r"'\''"]
    # …and the tokens after it are still seen.
    check texts(r"'\'' & suite") == @[r"'\''", "&", "suite"]
    check values(r"'\''")[0] == r"\'"

  test "a lone apostrophe degrades to punctuation":
    # The accent-quoted custom-literal operator name has no closing apostrophe
    # on the line.  A scanner that guessed "string" here would swallow the rest
    # of the file; the whole point is that it costs exactly one token.
    const source = "proc `'m`(v: string): int\nsuite \"s\""
    let tokens = scanNimSource(source)
    check source.identIs(tokens[^2], "suite")
    check tokens[^1].kind == ntkString
    check tokens[^1].value == "s"

  test "an apostrophe with no closer anywhere costs exactly one token":
    # The reported defect in its exact shape: one type-suffixed literal, and no
    # other apostrophe in the whole file. The previous scanner treated the
    # apostrophe as a string opener and consumed everything after it looking
    # for a closing quote, so every declaration below vanished.
    const source = "const n = 10485760'i64\n\n" &
      "suite \"round trip\":\n  test \"keeps it\":\n    discard\n"
    var names: seq[string] = @[]
    for token in scanNimSource(source):
      if token.kind == ntkString:
        names.add token.value
    check names == @["round trip", "keeps it"]

  test "apostrophes inside comments and strings are inert":
    check kinds("# it's fine") == @[ntkComment]
    check values("\"it's fine\"") == @["it's fine"]
    check kinds("#[ it's fine ]#") == @[ntkComment]

  test "raw string literals do not honour backslash escapes":
    # Source text: r"C:\dir\"  — the trailing backslash does NOT escape the
    # closing quote, so the literal ends there.
    const rawPath = "r\"C:\\dir\\\" & tail"
    let tokens = scanNimSource(rawPath)
    check tokens[0].kind == ntkString
    check tokens[0].prefix == "r"
    check tokens[0].value == "C:\\dir\\"
    check rawPath.identIs(tokens[^1], "tail")

  test "generalized raw string literals escape a quote by doubling it":
    # Source text: gr"a""b"
    let tokens = scanNimSource("gr\"a\"\"b\"")
    check tokens.len == 1
    check tokens[0].kind == ntkString
    check tokens[0].prefix == "gr"
    check tokens[0].value == "a\"b"

  test "triple-quoted strings close on the first non-extended terminator":
    const source = "\"\"\"quoted: \"\"not a close\"\" done\"\"\" & tail"
    let tokens = scanNimSource(source)
    check tokens[0].kind == ntkString
    check tokens[0].value == "quoted: \"\"not a close\"\" done"
    check source.identIs(tokens[^1], "tail")

  test "a triple-quoted string keeps quotes adjacent to its delimiters":
    # Nim closes a `"""` literal at the first `"""` NOT followed by another `"`,
    # which is what makes `""""abc""""` mean `"abc"`. Closing on the first
    # `"""` instead would end the literal one quote early and leave a stray
    # quote to open a phantom string over the rest of the line.
    const source = "\"\"\"\"abc\"\"\"\" & tail"
    let tokens = scanNimSource(source)
    check tokens[0].kind == ntkString
    check tokens[0].terminated
    check tokens[0].value == "\"abc\""
    check source.identIs(tokens[^1], "tail")

  test "the character-literal lookahead is bounded to a plausible body":
    # Both apostrophes are on ONE line, so the newline guard cannot help here:
    # only the length bound stops the accent-quoted name's apostrophe from
    # pairing with the real character literal further along and swallowing
    # `let b =` in between.
    const source = "let a = `'m`; let b = 'x'"
    let tokens = scanNimSource(source)
    check tokens[^1].kind == ntkChar
    check tokens[^1].value == "x"
    check source.identIs(tokens[^3], "b")

  test "a triple-quoted string can hide whole declarations":
    const source = "\"\"\"\nsuite \"fake\":\n  test \"fake\":\n\"\"\"\nsuite"
    let tokens = scanNimSource(source)
    check tokens[0].kind == ntkString
    check tokens[0].multiline
    check source.identIs(tokens[1], "suite")

  test "block comments nest, in both the plain and the doc form":
    check kinds("#[ a #[ b ]# c ]# tail") == @[ntkComment, ntkIdent]
    check kinds("##[ a ##[ b ]## c ]## tail") == @[ntkComment, ntkIdent]

  test "unterminated constructs stop at the line, not at the file":
    const source = "\"oops\nsuite \"real\""
    let tokens = scanNimSource(source)
    check tokens[0].kind == ntkString
    check not tokens[0].terminated
    check source.identIs(tokens[1], "suite")
    check tokens[2].terminated

  test "token geometry is 1-based and endColumn is the last character":
    let tokens = scanNimSource("  suite \"x\":")
    check tokens[0].line == 1
    check tokens[0].column == 3
    check tokens[0].endColumn == 7
    check tokens[1].column == 9
    check tokens[1].endColumn == 11

  test "line and column survive multi-line constructs":
    const source = "#[\n\n]#\nsuite"
    let tokens = scanNimSource(source)
    check source.identIs(tokens[^1], "suite")
    check tokens[^1].line == 4
    check tokens[^1].column == 1

  test "maskNimNonCode blanks comments and multi-line strings in place":
    let source = "import std/unittest # it's a comment\n" &
      "let s = \"\"\"\nimport nothing\n\"\"\"\n" &
      "let t = \"import inline\"\n"
    let masked = maskNimNonCode(source)
    # Byte-for-byte the same geometry: offsets and line numbers still line up
    # with the original, which is what makes a line-oriented scan safe.
    check masked.len == source.len
    check masked.splitLines.len == source.splitLines.len
    check masked.splitLines[0].strip == "import std/unittest"
    check "it's a comment" notin masked
    check "import nothing" notin masked
    # Single-line literals are preserved: `import "some/module"` is legal Nim.
    check "import inline" in masked
