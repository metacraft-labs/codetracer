## PLAT-42 — the ONE reading of an editor row's gutter text, for every suite
## and record that has to recover a line number from a row's text.
##
## Pure (no renderer, no shim), so the portable suites that read committed
## records can import it. The GPUI gutter is `pointer lane & mark lane &
## lane gap & right-aligned number` (`gpui/app/leaves.gutterRuns`), the order
## the desktop editor and the terminal use; the lanes' glyphs are skipped and
## the number is the first run of digits. Until 2026-09-23 the pointer followed
## the number and four suites each carried their own leading-digits loop, which
## a reordered gutter would have broken four times.
##
## The LANE GAP arrived on 2026-10-03 with `PLAT35-F13` / `PLAT35-F14` (the
## padding moved from in front of the lanes to between them and the number, so
## that each lane has a fixed cell index). It costs one more byte before the
## first digit and `MaxLaneBytes` below is what that budget is spent against.

import std/strutils

const MaxLaneBytes = 12
  ## The two lanes' glyphs, the lane gap and the number field's padding are at
  ## most a few UTF-8 sequences; a row whose first digit is further in than
  ## this is not a gutter.
  ##
  ## The worst case the GPUI gutter can produce is `▶` (3 bytes) + `●` (3) +
  ## the ASCII lane gap (1) + the padding of a four-digit number field (3) =
  ## 10, so a 9999-line file still reads. It must also stay BELOW 16: the
  ## negative case `gutterLineOf("def f(): return 1") == -1` holds because the
  ## `1` sits at byte 16, and a limit that reached it would turn a line of code
  ## into line 1.

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
  ## The name an inline-value CHIP's text starts with, as OCR reads the chip,
  ## or "".
  ##
  ## Until 2026-10-17 the window drew a row's values as a C comment after the
  ## code, `/* x: 1 */`, and this read the name out of the comment. The window
  ## now draws them as the desktop's flow does: one rounded `#1b1b1b` box per
  ## value, the name (#919191), then the value (bold #f3f3f3), led by a 30 px
  ## "view more" eye cell when the value is long. In the row's own OCR the
  ## chips are spelled exactly like more code (`results.append(value) results
  ## @[] value 5`), so the window record finds each box BY ITS GROUND, leaves
  ## the eye cell out, and OCRs the box alone; this parses that text, whose
  ## measured spellings are `mul <function mul at Ox7fffe862ch..`,
  ## `__builtins__ al("__name__", "builti`, `results a[]`, `value &` (a bold
  ## `5`) and `<stdout> CHNCCKS`.
  ##
  ## THE GRAMMAR: `name SPACE value` — `name` an identifier, or an event's
  ## `<identifier>` — and nothing in front of it. Anything else is "", not a
  ## guess: a chip read with its eye cell (`& mul <fun…`), a bare word with no
  ## value, or code (`results.append(value) …`, whose identifier runs into a
  ## `.`). Read from the CHIP, never from the row: a value is shown because
  ## its variable is named on the line, so "the name appears in the row" is
  ## true of every row that has one whether or not a value was drawn.
  var i = 0
  var name = ""
  if i < text.len and text[i] == '<':
    name.add '<'
    inc i
  if i >= text.len or not (text[i].isAlphaAscii or text[i] == '_'): return ""
  while i < text.len and (text[i].isAlphaNumeric or text[i] == '_'):
    name.add text[i]
    inc i
  if name[0] == '<':
    if i >= text.len or text[i] != '>': return ""
    name.add '>'
    inc i
  if i + 1 < text.len and text[i] == ' ' and text[i + 1] != ' ': name
  else: ""

func legiblyNames*(comment, name: string): bool =
  ## Whether a value comment's legible name is `name` — all of it, or, when
  ## the pane clipped it, a prefix of at least two characters.
  comment.len >= min(2, name.len) and name.startsWith(comment)

when isMainModule:
  # Chips as OCR read them off the 2026-10-17 window frames.
  doAssert valueCommentName("mul <function mul at Ox7fffe862ch..") == "mul"
  doAssert valueCommentName("__builtins__ al(\"__name__\", \"builti") ==
    "__builtins__"
  doAssert valueCommentName("OPERATIONS @[(\"+\", <function add at Ox7f.") ==
    "OPERATIONS"
  doAssert valueCommentName("results a[]") == "results"
  doAssert valueCommentName("value &") == "value"
  doAssert valueCommentName("<stdout> CHNCCKS") == "<stdout>"
  # Not chips: the row's own spelling, a chip read with its eye cell, a word
  # with no value, the retired comment spelling, nothing.
  doAssert valueCommentName("results.append(value) results @[] value &") == ""
  doAssert valueCommentName("& mul <function mul at Ox7fffe862ch..") == ""
  doAssert valueCommentName("results") == ""
  doAssert valueCommentName("results ") == ""
  doAssert valueCommentName("<stdout CHNCCKS") == ""
  doAssert valueCommentName("/* mul: <fun...") == ""
  doAssert valueCommentName("") == ""
  doAssert legiblyNames("re", "results")
  doAssert not legiblyNames("r", "results")
  doAssert not legiblyNames("mu", "results")
  doAssert gutterLineOf("44 def div") == 44
  doAssert gutterLineOf("▶ 44def div") == 44
  doAssert gutterLineOf("▶●2 \"\"\"calc") == 2
  doAssert gutterLineOf("●2 x") == 2
  doAssert gutterLineOf("def f(): return 1") == -1
  doAssert gutterLineOf("") == -1
