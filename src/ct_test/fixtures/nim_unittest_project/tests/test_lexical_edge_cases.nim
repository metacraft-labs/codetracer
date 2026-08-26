## Regression fixture for the Nim lexical scanner (``ct_test/nim_lexer``).
##
## Every ``suite``/``test`` declaration below is REAL and must be discovered;
## every string, comment and disabled block that merely *looks* like one must
## not be. The file exists because a scanner that treats ``'`` as a
## character-literal opener desyncs on numeric type suffixes such as
## ``10485760'i64`` and then silently drops every declaration up to the next
## apostrophe — the failure this fixture pins.

import std/[strutils, unittest]

type MyMeters = distinct int

proc `'m`(value: string): MyMeters =
  ## Custom numeric literal suffix: ``12'm``.
  MyMeters(parseInt(value))

proc gr(value: string): string =
  ## Backing proc for the generalized raw string literal ``gr"…"``.
  value

const
  # Integer type suffixes. The apostrophe is NOT a character literal.
  maxChunk = 10485760'i64
  smallCount = 0'u8
  # Underscore separators combined with a suffix.
  wide = 1_000_000'u32
  # Float type suffixes.
  ratio = 1.0'f32
  precise = 2.5'f64
  # Hexadecimal literal with a type suffix ('f' is also a hex digit here).
  mask = 0x1F'i64
  # Custom numeric literal.
  distance = 12'm
  # Character literals, including the escaped-apostrophe and escape forms.
  letter = 'a'
  quoteChar = '\''
  tabChar = '\t'
  hexChar = '\x41'
  # An apostrophe inside an ordinary string literal.
  possessive = "it's a string, not a type suffix"
  # A raw string ending in a backslash: `\` does not escape the closing quote.
  windowsish = r"C:\dir\"
  # A generalized raw string literal: `""` is how it escapes one quote.
  quoted = gr"a""b"
  # Doubled quotes inside a triple-quoted literal do not close it.
  banner = """quoted: ""not a close"" done"""
  # A here-doc that contains what looks like a whole test suite.
  fakeSource = """
suite "string suite":
  test "string test":
    discard
"""

# An apostrophe inside a line comment: it's inert, and so is test "comment test".

#[ Outer block comment: it's inert too.
   #[ Nested: suite "block commented suite":
        test "block commented test" ]#
   Still inside the outer comment. ]#

suite "lexical edges":
  test "type suffixes do not open character literals":
    check maxChunk == 10485760
    check smallCount == 0'u8
    check wide == 1_000_000'u32
    check ratio > 0'f32
    check precise > 0'f64
    check mask == 31
    check int(distance) == 12

  test "character literals are single tokens":
    check letter == 'a'
    check quoteChar == '\''
    check tabChar == '\t'
    check hexChar == 'A'

  test "apostrophes inside literals and comments are inert":
    check possessive.contains("it's")
    check fakeSource.contains("string suite")

  test "raw and generalized literals keep their backslashes and quotes":
    check windowsish.endsWith("\\")
    check quoted == "a\"b"
    check banner.contains("\"\"not a close\"\"")

when false:
  # Disabled in source: the compiler never instantiates this block, so no
  # runner can ever produce these cases and discovery must not claim them.
  suite "disabled suite":
    test "disabled case":
      check false

test "top level case after a disabled block":
  check true
