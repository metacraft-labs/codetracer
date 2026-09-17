## seq_line_store.nim — the INCUMBENT storage, behind the same seven
## operations as `text_store.nim`.
##
## This is `seq[string]`: what `isonim-tui/src/isonim_tui/widgets/textarea.nim`
## stores an editable document in today, and what PLAT-24 measured the rope
## against. It exists for three reasons, and none of them is history:
##
##   1. **It is the measurement's losing arm, and it is executed.** A gate
##      whose losing side is never run is a gate nobody has seen fail
##      (Verification-Harness-Traps.md §28's family). `benchmarks/
##      text_store_bench.nim` runs this store and the rope in the SAME process
##      at the SAME load, and prints both ratios.
##   2. **It is the suite's differential oracle.** Every behavioural case in
##      `test_editor_text_store.nim` runs against both stores and requires the
##      same answer, so the rope is checked against an independent
##      implementation of the same contract rather than against itself.
##   3. **It is the standing proof that the interface is narrow enough to
##      reverse the decision.** §4's risk is "the interface widens to
##      accommodate a rope and the choice becomes irreversible". Two
##      structurally unrelated implementations satisfying the same seven
##      operations is that risk answered mechanically.
##
## FIDELITY TO textarea.nim, and the one deliberate difference
## ------------------------------------------------------------------------
## `replaceRange` below is `applyDeleteRange` followed by `applyInsert`, with
## the same branches in the same order:
##
##   * an edit inside one line with no newline in the replacement is
##     `lines[line] = prefix & s & suffix` — `textarea.nim:755`, an assignment
##     to an EXISTING `seq` element. Its cost is the length of the line and
##     does not depend on which line it is. This is the arm that does not
##     discriminate between storages, and the benchmark prints it for exactly
##     that reason;
##   * an edit that introduces newlines is `lines[line] = prefix & parts[0]`
##     then one `lines.insert(...)` per added line — `textarea.nim:761-767`.
##     `seq.insert` shifts every element after the insertion point, so at line
##     1 of a 200,000-line document it moves ~200,000 strings and at the last
##     line it moves none. **This is the property the storage decision turns
##     on**;
##   * a multi-line delete joins the first prefix to the last suffix and then
##     calls `lines.delete(dropFrom)` once per removed line —
##     `textarea.nim:800-807`, which is one O(n) shift each rather than one
##     shift for the range.
##
## The one difference: `TextPos.column` here is a BYTE offset where
## `textarea.nim`'s `Caret.column` is a grapheme-cluster index, so the
## `clusterBoundaries` lookups at `textarea.nim:749` and `:779-784` are not
## reproduced. That changes what a column MEANS, not what the storage DOES —
## the `seq` operations, which are the subject of the measurement, are
## unchanged. Segmentation's own cost is measured separately by the benchmark,
## because PLAT-24 asks for it separately.
##
## `offsetOf` and `posOf` are O(number of lines) here, and that is faithful
## rather than lazy: `textarea.nim` maintains no line-start index of any kind,
## and adding one would make this store a different store. The benchmark
## prints the line-index cost as its own figure for both stores, so the
## difference is visible instead of folded into a keystroke.

import std/strutils

import ./text_store

export text_store.TextPos, text_store.textPos, text_store.`<`, text_store.`<=`

type
  SeqLineStore* = object
    lines: seq[string]

proc toSeqLineStore*(text: string): SeqLineStore =
  ## Construction. `textarea.nim:1303`: `t.lines = doc.split('\n')`, with the
  ## same empty-document convention.
  var ls = text.split('\n')
  if ls.len == 0: ls = @[""]
  SeqLineStore(lines: ls)

# ===========================================================================
# PRIMITIVES — the same seven as text_store.nim.
# ===========================================================================

func len*(s: SeqLineStore): int =
  ## O(number of lines): a `seq[string]` holds no total. `textarea.nim`'s
  ## `text()` pays the same walk plus a whole-document copy, on every edit,
  ## because the tree-sitter highlighter asks for it.
  result = s.lines.len - 1
  for line in s.lines:
    result += line.len

func lineCount*(s: SeqLineStore): int =
  s.lines.len

func lineLen*(s: SeqLineStore; line: int): int =
  if line < 0 or line >= s.lines.len: 0 else: s.lines[line].len

func offsetOf*(s: SeqLineStore; pos: TextPos): int =
  let line = clamp(pos.line, 0, s.lines.len - 1)
  result = 0
  for i in 0 ..< line:
    result += s.lines[i].len + 1
  result += clamp(pos.column, 0, s.lines[line].len)

func posOf*(s: SeqLineStore; offset: int): TextPos =
  var remaining = max(0, offset)
  for i in 0 ..< s.lines.len:
    if remaining <= s.lines[i].len:
      return textPos(i, remaining)
    remaining -= s.lines[i].len + 1
  textPos(s.lines.len - 1, s.lines[^1].len)

func slice*(s: SeqLineStore; a, b: TextPos): string =
  var lo = textPos(clamp(a.line, 0, s.lines.len - 1), 0)
  lo.column = clamp(a.column, 0, s.lines[lo.line].len)
  var hi = textPos(clamp(b.line, 0, s.lines.len - 1), 0)
  hi.column = clamp(b.column, 0, s.lines[hi.line].len)
  if hi < lo: swap(lo, hi)
  if lo.line == hi.line:
    return s.lines[lo.line][lo.column ..< hi.column]
  result = s.lines[lo.line][lo.column ..< s.lines[lo.line].len]
  for i in lo.line + 1 ..< hi.line:
    result.add '\n'
    result.add s.lines[i]
  result.add '\n'
  result.add s.lines[hi.line][0 ..< hi.column]

proc replaceRange*(s: var SeqLineStore; a, b: TextPos; text: string) =
  var lo = textPos(clamp(a.line, 0, s.lines.len - 1), 0)
  lo.column = clamp(a.column, 0, s.lines[lo.line].len)
  var hi = textPos(clamp(b.line, 0, s.lines.len - 1), 0)
  hi.column = clamp(b.column, 0, s.lines[hi.line].len)
  if hi < lo: swap(lo, hi)

  # --- applyDeleteRange (textarea.nim:772-811), byte columns --------------
  if lo != hi:
    if lo.line == hi.line:
      let line = s.lines[lo.line]
      s.lines[lo.line] = line[0 ..< lo.column] & line[hi.column ..< line.len]
    else:
      let firstLine = s.lines[lo.line]
      let lastLine = s.lines[hi.line]
      s.lines[lo.line] =
        firstLine[0 ..< lo.column] & lastLine[hi.column ..< lastLine.len]
      # One `delete` per removed line — textarea.nim:805-807, and one O(n)
      # shift each.
      for _ in 0 ..< hi.line - lo.line:
        s.lines.delete(lo.line + 1)

  # --- applyInsert (textarea.nim:745-767), byte columns -------------------
  if text.len == 0: return
  let cur = s.lines[lo.line]
  let prefix = cur[0 ..< lo.column]
  let suffix = cur[lo.column ..< cur.len]
  let parts = text.split('\n')
  if parts.len == 1:
    # textarea.nim:755 — an assignment to an existing element.
    s.lines[lo.line] = prefix & text & suffix
  else:
    # textarea.nim:761-767 — one `seq.insert` per added line.
    s.lines[lo.line] = prefix & parts[0]
    var insertIdx = lo.line + 1
    for i in 1 ..< parts.len - 1:
      s.lines.insert(parts[i], insertIdx)
      inc insertIdx
    s.lines.insert(parts[^1] & suffix, insertIdx)

# ===========================================================================
# DERIVED — defined in terms of the seven above.
# ===========================================================================

func text*(s: SeqLineStore): string =
  ## `textarea.nim:281`'s `text()`: `lines.join("\n")`.
  s.lines.join("\n")

func lineText*(s: SeqLineStore; line: int): string =
  if line < 0 or line >= s.lines.len: "" else: s.lines[line]

proc insert*(s: var SeqLineStore; at: TextPos; text: string) =
  s.replaceRange(at, at, text)

proc delete*(s: var SeqLineStore; a, b: TextPos) =
  s.replaceRange(a, b, "")

func `$`*(s: SeqLineStore): string =
  s.text
