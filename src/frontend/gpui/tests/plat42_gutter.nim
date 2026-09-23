## PLAT-42 — the ONE reading of an editor row's gutter text, for every suite
## and record that has to recover a line number from a row's text.
##
## Pure (no renderer, no shim), so the portable suites that read committed
## records can import it. The GPUI gutter is `pointer lane & mark lane &
## number` (`gpui/app/leaves.renderEditorRow`), the order the desktop editor
## and the terminal use; the lanes' glyphs are skipped and the number is the
## first run of digits. Until 2026-09-23 the pointer followed the number and
## four suites each carried their own leading-digits loop, which a reordered
## gutter would have broken four times.

import std/strutils

const MaxLaneBytes = 12
  ## The two lanes' glyphs are at most a few UTF-8 sequences; a row whose
  ## first digit is further in than this is not a gutter.

func gutterLineOf*(text: string): int =
  ## The line number a row's text starts with, or -1.
  var i = 0
  while i < text.len and i < MaxLaneBytes and not text[i].isDigit:
    inc i
  var digits = ""
  while i < text.len and text[i].isDigit:
    digits.add text[i]
    inc i
  if digits.len == 0: -1 else: parseInt(digits)

func valueCommentName*(text: string): string =
  ## The name an inline-value comment starts with — `x` in `/* x: 1 */`, or
  ## the legible part of it when the pane clipped the comment (`/* re…`) — or
  ## "". Read from the COMMENT, never from the code: a value is shown because
  ## its variable is named on the line, so "the name appears in the row" is
  ## true of every row that has one whether or not a value was drawn.
  var at = text.find("/*")
  while at >= 0:
    var i = at + 2
    while i < text.len and text[i] == ' ': inc i
    var name = ""
    while i < text.len and (text[i].isAlphaNumeric or text[i] == '_'):
      name.add text[i]
      inc i
    if name.len > 0: return name
    at = text.find("/*", at + 2)
  ""

func legiblyNames*(comment, name: string): bool =
  ## Whether a value comment's legible name is `name` — all of it, or, when
  ## the pane clipped it, a prefix of at least two characters.
  comment.len >= min(2, name.len) and name.startsWith(comment)

when isMainModule:
  doAssert valueCommentName("113 return results/* re...") == "re"
  doAssert valueCommentName("56 \"*\": mul/* mul: <fun...") == "mul"
  doAssert valueCommentName("45 \"\"\"Floor division. *//*") == ""
  doAssert legiblyNames("re", "results")
  doAssert not legiblyNames("r", "results")
  doAssert not legiblyNames("mu", "results")
  doAssert gutterLineOf("44 def div") == 44
  doAssert gutterLineOf("▶ 44def div") == 44
  doAssert gutterLineOf("▶●2 \"\"\"calc") == 2
  doAssert gutterLineOf("●2 x") == 2
  doAssert gutterLineOf("def f(): return 1") == -1
  doAssert gutterLineOf("") == -1
