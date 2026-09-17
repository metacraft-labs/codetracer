## text_store.nim — the editor ViewModel's text storage, and the interface
## that keeps the choice of storage reversible.
##
## Owns: Editor-ViewModel.md §4. Everything above it — positions, anchors,
## change application, wrap invalidation — is written against THIS interface
## and never against the structure underneath it.
##
## =========================================================================
## THE INTERFACE — four categories, seven operations. Count them.
## =========================================================================
##
## §4 says the interface is "lengths, a line index, a slice, and a
## replace-range", and that "if more than that leaks upward, the choice has
## stopped being an implementation detail". So it is written here as a list
## somebody can count, and `test_editor_text_store.nim` counts it — a source
## scan over this file's PRIMITIVES section that fails by name on an eighth
## exported operation.
##
##   lengths          `len`          total bytes in the document
##                    `lineCount`    number of lines
##                    `lineLen`      bytes on one line, newline excluded
##   a line index     `offsetOf`     TextPos -> byte offset
##                    `posOf`        byte offset -> TextPos
##   a slice          `slice`        the text between two positions
##   a replace-range  `replaceRange` replace the text between two positions
##
## Construction (`toTextStore`) is not an operation on a store and is listed
## separately. Everything in the DERIVED section below is defined in terms of
## the seven and adds no capability — `text`, `lineText`, `insert`, `delete`,
## `==`. That is the difference between a convenience and a widening, and the
## scan enforces it by section.
##
## =========================================================================
## COORDINATES
## =========================================================================
##
## `TextPos.column` is a **byte** offset inside its line, not a grapheme
## cluster index and not a rune index. This is deliberate and it is the one
## place this module diverges from `isonim-tui`'s `Caret`, whose `column` IS a
## cluster index (`textarea.nim`, "column is a grapheme-cluster index inside
## the line").
##
## The reason is that cluster indices are not a storage concept. Turning one
## into a byte offset means segmenting the line under UAX #29, which is a
## per-call `seq` allocation (`width.nim`'s `graphemeClusters` decodes every
## rune of the line into two `seq`s before it yields), and putting it inside
## the store would charge every index operation for it. Cluster editing is
## composed ABOVE this interface instead: read the line with `lineText`,
## segment it once, and hand the resulting byte column back in. The suite does
## exactly that, on a ZWJ family, so "one backspace deletes one glyph" is a
## property this store is shown to support rather than one it re-implements.
##
## A position is clamped into the document by `offsetOf`: a line past the end
## resolves to the end, a column past the end of its line to the end of that
## line. An offset that lands INSIDE a UTF-8 code point is not clamped — it
## raises from `replaceRange`, because silently moving an edit is how a
## document acquires invalid bytes that surface three layers away.
##
## =========================================================================
## WHICH STRUCTURE, AND WHY THIS ONE
## =========================================================================
##
## A rope: `editor/rope.nim`, a uniform-depth tree over UTF-8 chunks with
## cached byte and newline summaries. PLAT-24 chose it by measurement against
## a ratio fixed before the measurement; the numbers, the corpus and the date
## are in Editor-ViewModel.md §4, and the measurement itself is
## `viewmodel/benchmarks/text_store_bench.nim`, which runs the incumbent
## `seq[string]` arm in the same process at the same load so the losing arm is
## something somebody has seen lose.
##
## The incumbent is still here, behind the same seven operations, as
## `editor/seq_line_store.nim`. It is not dead code: it is the measurement's
## other arm, it is the differential oracle the suite checks this store
## against, and it is the standing proof that the interface is narrow enough
## for the decision to be reversed.

import ./rope

export rope.RopeStats, rope.checkInvariants, rope.MaxLeafBytes,
       rope.MaxChildren

type
  TextPos* = object
    ## A position in the document. `column` is a BYTE offset inside `line`.
    line*: int
    column*: int

  TextStore* = object
    ## The editor ViewModel's document storage. A value: assignment copies,
    ## and the rope's nodes are shared structurally until one side writes.
    doc: rope.Rope

func textPos*(line, column: int): TextPos {.inline.} =
  TextPos(line: line, column: column)

func `<`*(a, b: TextPos): bool =
  if a.line != b.line: a.line < b.line else: a.column < b.column

func `<=`*(a, b: TextPos): bool =
  not (b < a)

proc toTextStore*(text: string): TextStore =
  ## Construction. Not one of the seven.
  TextStore(doc: rope.initRope(text))

# ===========================================================================
# PRIMITIVES — the seven. Nothing else exported above the DERIVED marker.
# ===========================================================================

func len*(s: TextStore): int =
  ## Total byte length of the document.
  rope.len(s.doc)

func lineCount*(s: TextStore): int =
  ## Number of lines. A document always has at least one, and a trailing
  ## newline means a final empty line — the same convention `seq[string]`
  ## gets from `split('\n')`.
  rope.newlineCount(s.doc) + 1

proc lineLen*(s: TextStore; line: int): int =
  ## Bytes on `line`, the terminating newline excluded.
  if line < 0 or line >= s.lineCount: return 0
  let start = rope.lineStartOffset(s.doc, line)
  let stop =
    if line == s.lineCount - 1: rope.len(s.doc)
    else: rope.lineStartOffset(s.doc, line + 1) - 1
  max(0, stop - start)

proc offsetOf*(s: TextStore; pos: TextPos): int =
  ## The line index, forward. Clamps a position into the document.
  ##
  ## Column 0 short-circuits: a descent for the line's start answers it, and
  ## the second descent that would establish the line's END is only needed
  ## when a column has to be clamped against it. Both stores answer a
  ## line-start position without measuring the line, so the comparison the
  ## benchmark takes is between two stores doing the same work.
  let last = s.lineCount - 1
  let line = clamp(pos.line, 0, last)
  let start = rope.lineStartOffset(s.doc, line)
  if pos.column <= 0: return start
  let stop =
    if line == last: rope.len(s.doc)
    else: rope.lineStartOffset(s.doc, line + 1) - 1
  start + min(pos.column, max(0, stop - start))

proc posOf*(s: TextStore; offset: int): TextPos =
  ## The line index, backward.
  let off = clamp(offset, 0, rope.len(s.doc))
  let line = rope.lineOfOffset(s.doc, off)
  TextPos(line: line, column: off - rope.lineStartOffset(s.doc, line))

proc slice*(s: TextStore; a, b: TextPos): string =
  ## The text between two positions, `b` exclusive.
  let lo = s.offsetOf(a)
  let hi = s.offsetOf(b)
  rope.sliceBytes(s.doc, min(lo, hi), max(lo, hi))

proc replaceRange*(s: var TextStore; a, b: TextPos; text: string) =
  ## Replace `[a, b)` with `text`. Raises `ValueError` when a resolved offset
  ## falls inside a UTF-8 code point.
  var lo = s.offsetOf(a)
  var hi = if a == b: lo else: s.offsetOf(b)
  if lo > hi: swap(lo, hi)
  let loByte = rope.byteAt(s.doc, lo)
  if loByte >= 0 and (uint8(loByte) and 0xC0'u8) == 0x80'u8:
    raise newException(ValueError,
      "text store: offset " & $lo & " is inside a UTF-8 code point")
  if hi != lo:
    let hiByte = rope.byteAt(s.doc, hi)
    if hiByte >= 0 and (uint8(hiByte) and 0xC0'u8) == 0x80'u8:
      raise newException(ValueError,
        "text store: offset " & $hi & " is inside a UTF-8 code point")
  rope.replaceBytes(s.doc, lo, hi, text)

# ===========================================================================
# DERIVED — defined in terms of the seven above. Adds no capability.
# ===========================================================================

proc text*(s: TextStore): string =
  ## The whole document. `slice` over the whole range.
  s.slice(textPos(0, 0), textPos(s.lineCount - 1, high(int)))

proc lineText*(s: TextStore; line: int): string =
  ## One line without its newline. `slice` over one line's extent.
  s.slice(textPos(line, 0), textPos(line, s.lineLen(line)))

proc insert*(s: var TextStore; at: TextPos; text: string) =
  s.replaceRange(at, at, text)

proc delete*(s: var TextStore; a, b: TextPos) =
  s.replaceRange(a, b, "")

proc `==`*(a, b: TextStore): bool =
  a.text == b.text

proc `$`*(s: TextStore): string =
  s.text

# ===========================================================================
# STRUCTURAL CHECK — not an operation on text, and not derived from one.
# ===========================================================================

proc invariants*(s: TextStore; st: var RopeStats): string =
  ## The structural check the suite asserts on: "" when the tree is a sound,
  ## balanced rope, otherwise the first violation by name. Exposed here
  ## because a store that behaves correctly while degenerating into a list is
  ## exactly the outcome PLAT-24's risk section names.
  rope.checkInvariants(s.doc, st)
