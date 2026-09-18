## PLAT-27 — the pinned examples: the decisions, and the measurements they were
## taken on.
##
## Subject: `viewmodel/editor/wrap.nim`.
##
## The laws in `test_editor_wrap_laws.nim` are quantified over a 90-cell cross
## product and say nothing about WHICH answer is right — a model that wrapped
## every line after one cell satisfies every one of them. This file is the other
## half: each case pins one answer, and every case here is a decision somebody
## can disagree with rather than an invariant nobody can.
##
## **Every number in this file was measured before it was written.** The
## campaign's recurring failure is a figure that was plausible when it was typed
## and has been decorative ever since.
##
## ARMING: `run-plat27-coordinate-mutations.py`.

import std/[options, sequtils, strutils, unittest]

import ../../editor/change_set
import ../../editor/selection
import ../../editor/wrap
import ../generators/wrap_generator

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 136

proc rowsOf(c: WrapCache): seq[wrap.DisplayRow] =
  result = @[]
  for i in 0 ..< c.rowCount: result.add c.rowAt(i)

proc rowTexts(c: WrapCache; doc: string): seq[string] =
  result = @[]
  for i in 0 ..< c.rowCount: result.add c.rowText(doc, i)

# ===========================================================================
# THE DECISION §5 AND §9 DISAGREED ABOUT
# ===========================================================================

suite "PLAT-27 — the wrap configuration is a parameter, and what that costs":

  test "ONE DOCUMENT, TWO RENDERERS, TWO WIDTHS, BOTH ANSWERING — PLAT-34's shape":
    # Editor-ViewModel.md §5 said `EditorState` carries the wrap configuration;
    # §3.1 and §9 said the per-renderer settings enter as parameters. The
    # settled answer is the parameter, and this is the case that could not
    # exist under the other design.
    let doc = "one two three four five six seven eight nine ten\nshort\n"
    let terminal = initWrapCache(doc, wrapSettings(80, 4, awNarrow))
    let window = initWrapCache(doc, wrapSettings(12, 4, awNarrow))
    counted terminal.rowCount == 3
    counted window.rowCount == 6
    counted terminal.lineCount == window.lineCount
    # The same logical position, two display answers, both correct.
    let p = textPos(0, 20)
    counted terminal.toDisplay(p) == DisplayPos(row: 0, column: 20)
    counted window.toDisplay(p) == DisplayPos(row: 1, column: 8)
    counted terminal.toLogical(terminal.toDisplay(p)) == p
    counted window.toLogical(window.toDisplay(p)) == p

  test "THE COST, PINNED: a cache handed another document RAISES rather than repairing":
    # Cost 1 of the decision: the cache is per renderer AND per document
    # version, so invalidation is N calls and a front-end can forget one.
    # §36a — the guard is a `raise`, so the first wrong answer is the last one.
    let doc = "alpha\nbeta\n"
    let c = initWrapCache(doc, wrapSettings(3, 4, awNarrow))
    var raised = ""
    try:
      c.refuseStaleCache(doc & "gamma")
    except WrapError as e:
      raised = e.msg
    counted raised.len > 0
    counted raised.contains("built from a document of 11 bytes")
    counted raised.contains("asked about one of 16")
    # AND THE RESIDUAL IS REAL, which is why it is written in the module rather
    # than only in a design note: two documents of the same length pass the
    # guard. `LAW-C6` is the check that the content is right.
    var slipped = true
    try:
      c.refuseStaleCache("ALPHA\nBETA\n")
    except WrapError:
      slipped = false
    counted slipped

  test "`rewrap` reuses the cluster metrics and equals a fresh build":
    # Cost 3's compensation: the decision makes "the same document at another
    # width" cheap, and a decision whose benefit has no call site is a decision
    # nobody can price.
    let doc = docById("c5-cjk-short")
    let base = initWrapCache(doc, wrapSettings(80, 4, awNarrow))
    for w in [4, 7, 20, 41]:
      counted rowsOf(base.rewrap(w)) ==
              rowsOf(initWrapCache(doc, wrapSettings(w, 4, awNarrow)))
    counted base.rewrap(80).rowCount == base.rowCount

# ===========================================================================
# WRAPPING ITSELF — the answers, not the invariants
# ===========================================================================

suite "PLAT-27 — what the wrap actually does":

  test "a row breaks BEFORE the cluster that would overflow, and never inside one":
    let doc = "abcdefghij"
    let c = initWrapCache(doc, wrapSettings(4, 4, awNarrow))
    counted rowTexts(c, doc) == @["abcd", "efgh", "ij"]
    counted c.rowAt(0).width == 4
    counted c.rowAt(2).width == 2

  test "A CLUSTER WIDER THAN THE WRAP COLUMN OCCUPIES A ROW ALONE AND OVERFLOWS IT":
    # The alternative is to split it, and half a CJK ideograph is the defect
    # the corpus exists to catch. The overflow is the DECISION; it is not a
    # bug that the row is wider than the column.
    let doc = "a漢b"
    let c = initWrapCache(doc, wrapSettings(1, 4, awNarrow))
    counted rowTexts(c, doc) == @["a", "漢", "b"]
    counted c.rowAt(1).width == 2
    counted c.rowAt(1).width > 1
    # **AND WHEN IT IS THE LINE'S FIRST CLUSTER**, which is the case the
    # `cells > 0` guard in `wrapLine` exists for and the only one that
    # distinguishes it: without the guard the loop emits an EMPTY row before
    # every over-wide cluster that starts a row, forever widening the document
    # by rows nothing can be painted on. Measured rather than reasoned about —
    # the arm that removes the guard leaves the case above green.
    let doc2 = "漢ab"
    let c2 = initWrapCache(doc2, wrapSettings(1, 4, awNarrow))
    counted rowTexts(c2, doc2) == @["漢", "a", "b"]
    counted c2.rowCount == 3
    counted c2.rowAt(0).width == 2

  test "A ZWJ FAMILY IS ONE CLUSTER AND ONE ROW — it is never wrapped in half":
    # `textarea.nim` already edits by grapheme cluster over UAX #29 and nothing
    # in the tree asserted it; this is the wrap-layer half of that claim.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    let doc = "ab" & family & "cd"
    let c = initWrapCache(doc, wrapSettings(3, 4, awNarrow))
    let texts = rowTexts(c, doc)
    # The family is EIGHTEEN bytes and TWO cells, so at a wrap column of 3 it
    # shares a row with one more cell and is never divided.
    counted family.len == 18
    counted clusterDisplayWidth(family, awNarrow) == 2
    counted texts == @["ab", family & "c", "d"]
    # The family's bytes are never divided: no row holds a PROPER, non-empty
    # prefix or suffix of it.
    var split = 0
    for t in texts:
      for k in 1 ..< family.len:
        if t.endsWith(family[0 ..< k]) or t.startsWith(family[k .. ^1]):
          inc split
    counted split == 0

  test "an empty line is ONE display row of width 0":
    let doc = "a\n\nb"
    let c = initWrapCache(doc, wrapSettings(1, 4, awNarrow))
    counted c.lineCount == 3
    counted c.rowCount == 3
    counted c.rowAt(1).width == 0
    counted c.rowText(doc, 1) == ""

  test "a document of N lines has at least N rows, and exactly N with soft wrap off":
    let doc = docById("c8-tabs-short")
    let off = initWrapCache(doc, wrapSettings(0, 4, awNarrow))
    counted off.rowCount == off.lineCount
    let on = initWrapCache(doc, wrapSettings(8, 4, awNarrow))
    counted on.rowCount > on.lineCount

# ===========================================================================
# TABS — corpus class 8's reason for existing
# ===========================================================================

suite "PLAT-27 — tabs at wrap boundaries":

  test "THE TAB STOP GRID IS THE LOGICAL LINE'S, AND WRAPPING PARTITIONS THE CELLS":
    # The decision, pinned. The alternative — restarting the grid at each
    # display row — makes a cluster's width depend on where the wrap put it,
    # which makes the wrap depend on itself.
    #
    # `"ab\tcd\tef"` at tab size 4 expands to columns
    #   a0 b1 <tab 2..3> c4 d5 <tab 6..7> e8 f9   — width 10.
    let doc = "ab\tcd\tef"
    let flat = initWrapCache(doc, wrapSettings(0, 4, awNarrow))
    counted flat.metricsOf(0).width == 10
    let c = initWrapCache(doc, wrapSettings(5, 4, awNarrow))
    counted rowTexts(c, doc) == @["ab\tc", "d\tef"]
    counted c.rowAt(0).width == 5
    # **THE SECOND ROW IS THE EVIDENCE.** It begins at LINE column 5, and the
    # tab on it advances to the LINE's next stop — column 6 to column 8, two
    # cells — so the row is `d`(1) + tab(2) + `e`(1) + `f`(1) = 5 cells. Had
    # the grid restarted at the row's own left edge the tab would have run from
    # row-column 1 to row-column 4, three cells, and the row would be 6.
    counted c.rowAt(1).startColumn == 5
    counted c.rowAt(1).width == 5
    counted c.metricsOf(0).clusters[5].cells == 2
    counted c.metricsOf(0).clusters[5].column == 6

  test "A TAB WHOSE EXPANSION CROSSES THE WRAP COLUMN MOVES WHOLE":
    # A tab is a cluster, so the break is before it — never through it.
    # `"abcde\tfg"` at tab size 4: the tab begins at column 5 and runs to
    # column 8, three cells. At a wrap column of 6 it does not fit, so the
    # break is BEFORE it and it starts the next row — still three cells wide,
    # because its stop is the LINE's.
    let doc = "abcde\tfg"
    let c = initWrapCache(doc, wrapSettings(6, 4, awNarrow))
    counted rowTexts(c, doc) == @["abcde", "\tfg"]
    counted c.rowAt(0).width == 5
    counted c.rowAt(1).startColumn == 5
    counted c.rowAt(1).width == 5
    counted c.metricsOf(0).clusters[5].cells == 3

  test "`tabSize = 0` IS THE TERMINAL'S MODEL, AND IT IS A SETTING RATHER THAN A DIVERGENCE":
    # `clusterDisplayWidth` reports a tab as 0 cells — it is a control
    # character, not a glyph — so `TabsAsClusters` is exactly what
    # `isonim-tui` does, and it is what `DIFF-2` runs at.
    let doc = "ab\tcd"
    let expanded = initWrapCache(doc, wrapSettings(0, 4, awNarrow))
    let asCluster = initWrapCache(doc, wrapSettings(0, TabsAsClusters, awNarrow))
    counted TabsAsClusters == 0
    counted expanded.metricsOf(0).width == 6
    counted asCluster.metricsOf(0).width == 4
    counted asCluster.metricsOf(0).clusters[2].cells == 0

  test "the tab size changes the columns, measured at 2, 4 and 8":
    let doc = "a\tb\tc"
    var widths: seq[int] = @[]
    for tab in [2, 4, 8]:
      widths.add initWrapCache(doc, wrapSettings(0, tab, awNarrow)).metricsOf(0).width
    counted widths == @[5, 9, 17]

# ===========================================================================
# THE COORDINATE CONVENTIONS
# ===========================================================================

suite "PLAT-27 — the two mappings, pinned":

  test "A POSITION AT A WRAP BOUNDARY IS THE START OF THE FOLLOWING ROW":
    # It has to be one of the two or the map is not a function. The start of
    # the next row is where the caret is painted, and it is what makes the
    # end-of-row position of a continuing row non-canonical.
    let doc = "abcdefgh"
    let c = initWrapCache(doc, wrapSettings(4, 4, awNarrow))
    counted c.toDisplay(textPos(0, 4)) == DisplayPos(row: 1, column: 0)
    counted c.toDisplay(textPos(0, 3)) == DisplayPos(row: 0, column: 3)
    counted c.isCanonicalDisplayPos(DisplayPos(row: 1, column: 0))
    counted not c.isCanonicalDisplayPos(DisplayPos(row: 0, column: 4))
    counted c.isCanonicalDisplayPos(DisplayPos(row: 1, column: 4))
    # And the non-canonical position still ANSWERS — it is the same point.
    counted c.toLogical(DisplayPos(row: 0, column: 4)) == textPos(0, 4)

  test "A BYTE THAT IS NOT A CLUSTER BOUNDARY ANSWERS WITH ITS CLUSTER'S COLUMN":
    # Deliverable 2's *"the answer for a position that is not a cluster
    # boundary"*, pinned. `漢` is three bytes and two cells.
    let doc = "a漢b"
    let c = initWrapCache(doc, wrapSettings(0, 4, awNarrow))
    counted c.toDisplay(textPos(0, 1)) == DisplayPos(row: 0, column: 1)
    counted c.toDisplay(textPos(0, 2)) == DisplayPos(row: 0, column: 1)
    counted c.toDisplay(textPos(0, 3)) == DisplayPos(row: 0, column: 1)
    counted c.toDisplay(textPos(0, 4)) == DisplayPos(row: 0, column: 3)
    # The INTERIOR CELL of the wide cluster is a display position and is NOT a
    # cluster boundary; it resolves forward, never to the cluster's start.
    counted not c.isDisplayClusterBoundary(DisplayPos(row: 0, column: 2))
    counted c.isDisplayClusterBoundary(DisplayPos(row: 0, column: 1))
    # **IT SNAPS BACK, NOT FORWARD.** A pointer on the ideograph's right-hand
    # cell is on the ideograph, so the caret does not jump over it. The map
    # stays monotone: bytes 0, 1, 1, 4 over columns 0, 1, 2, 3.
    counted c.toLogical(DisplayPos(row: 0, column: 2)) == textPos(0, 1)
    counted c.toLogical(DisplayPos(row: 0, column: 0)) == textPos(0, 0)
    counted c.toLogical(DisplayPos(row: 0, column: 1)) == textPos(0, 1)
    counted c.toLogical(DisplayPos(row: 0, column: 3)) == textPos(0, 4)

  test "A ZERO-WIDTH CLUSTER SHARES ITS COLUMN, WHICH IS WHY `LAW-C1` IS NOT AN IDENTITY":
    # §3.3a's measurement, in its smallest form. `\x01` is a C0 control: one
    # cluster, zero cells. Two logical positions, one display column.
    let doc = "a\x01b"
    let c = initWrapCache(doc, wrapSettings(0, 4, awNarrow))
    counted c.metricsOf(0).clusters.len == 3
    counted c.metricsOf(0).clusters[1].cells == 0
    counted c.toDisplay(textPos(0, 1)) == DisplayPos(row: 0, column: 1)
    counted c.toDisplay(textPos(0, 2)) == DisplayPos(row: 0, column: 1)
    # The round trip returns the CANONICAL one of the two, and it is not the
    # first: the position a caret at that column would occupy.
    counted c.toLogical(DisplayPos(row: 0, column: 1)) == textPos(0, 2)
    counted columnCanonical(c.metricsOf(0), 1) == 2
    counted columnCanonical(c.metricsOf(0), 2) == 2
    # THE CORPUS-WIDE FIGURE THE DECISION WAS TAKEN ON, re-measured here so it
    # cannot go stale in prose.
    var zero = 0
    for d in CorpusDocs:
      for line in d.text.split('\n'):
        for cl in graphemeClusters(line):
          if clusterDisplayWidth(cl.text, awNarrow) == 0: inc zero
    counted zero == 7352

  test "the display row of a CRLF line ends BEFORE the CR, as PLAT-26's `lineEnd` does":
    # PLAT-24's `unrepresentable.tsv` row 2: CRLF is one cluster under GB3 and
    # the store splits on `'\n'`, so the line's end is INSIDE a cluster. The
    # projection inherits that and does not pretend otherwise: the CR is on the
    # line, is a cluster of its own there, and is zero-width.
    let doc = "ab\r\ncd"
    let c = initWrapCache(doc, wrapSettings(0, 4, awNarrow))
    counted c.lineCount == 2
    counted c.metricsOf(0).byteLen == 3
    counted c.metricsOf(0).width == 2
    counted c.rowText(doc, 0) == "ab\r"

# ===========================================================================
# THE CACHE'S SPLICE
# ===========================================================================

suite "PLAT-27 — the wrap cache's splice":

  proc spliceCase(doc: string; cs: ChangeSet; settings: WrapSettings):
      tuple[a, b: seq[wrap.DisplayRow]] =
    let newDoc = cs.apply(doc)
    let c = initWrapCache(doc, settings)
    (rowsOf(c.updateWrapCache(doc, cs, newDoc)),
     rowsOf(initWrapCache(newDoc, settings)))

  test "an edit INSIDE a line re-wraps that line from its START, not from the edit":
    # `LAW-C6`'s published killer is *"skip invalidation for a region above the
    # edit"*, and the region above an edit that this function nonetheless
    # recomputes is the part of the edit's own line that precedes it: a cluster
    # inserted at column 2 moves every row boundary after it.
    let doc = "abcdefgh\nzz\n"
    let settings = wrapSettings(3, 4, awNarrow)
    let before = initWrapCache(doc, settings)
    counted rowTexts(before, doc) == @["abc", "def", "gh", "zz", ""]
    let cs = changeSet(doc.len, 2, 2, "XY")
    let r = spliceCase(doc, cs, settings)
    counted r.a == r.b
    # FIVE ROWS BEFORE, SIX AFTER: the edit added two cells to a line that was
    # already wrapping, so a row boundary moved and a row appeared.
    counted r.a.len == 6
    let after = cs.apply(doc)
    counted rowTexts(before.updateWrapCache(doc, cs, after), after) ==
            @["abX", "Ycd", "efg", "h", "zz", ""]

  test "an edit that DELETES a newline merges two lines and the splice follows":
    let doc = "abc\ndef\nghi\n"
    let settings = wrapSettings(4, 4, awNarrow)
    let cs = changeSet(doc.len, 3, 4, "")
    let r = spliceCase(doc, cs, settings)
    counted r.a == r.b
    counted initWrapCache(doc, settings).lineCount == 4
    counted initWrapCache(cs.apply(doc), settings).lineCount == 3

  test "an edit that ADDS newlines splits a line and the lines below are re-stamped":
    let doc = "abcdef\nzz\n"
    let settings = wrapSettings(9, 4, awNarrow)
    let cs = changeSet(doc.len, 3, 3, "\nQ\n")
    let r = spliceCase(doc, cs, settings)
    counted r.a == r.b
    # The row for `zz` is carried over byte for byte and only its line index
    # moves — which is what row offsets being LINE-RELATIVE buys.
    counted r.a[^2].line == 3
    counted r.a[^2].startByte == 0
    counted r.a[^2].endByte == 2

  test "the IDENTITY change set does not re-wrap anything":
    let doc = "abcdefgh\n"
    let settings = wrapSettings(3, 4, awNarrow)
    let c = initWrapCache(doc, settings)
    let updated = c.updateWrapCache(doc, identityChangeSet(doc.len), doc)
    counted rowsOf(updated) == rowsOf(c)

  test "a change set that does not MATCH the document is refused by name":
    let doc = "abc"
    let c = initWrapCache(doc, wrapSettings(2, 4, awNarrow))
    var msg = ""
    try:
      discard c.updateWrapCache(doc, changeSet(99, 0, 0, "x"), "xabc")
    except WrapError as e:
      msg = e.msg
    counted msg.contains("the change set is over a document of 99 bytes")

# ===========================================================================
# DISPLAY MOTIONS AND THE GUTTER
# ===========================================================================

suite "PLAT-27 — display motions, pinned":

  test "`gj` STEPS ONE DISPLAY ROW INSIDE ONE LOGICAL LINE — the motion §9 exists for":
    let doc = "abcdefghij\nz"
    let ctx = initDisplayCtx(doc, wrapSettings(4, 4, awNarrow))
    counted ctx.cache.rowCount == 4
    counted ctx.cache.lineCount == 2
    var r = caret(0)
    r = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formMove), r)
    counted r.head == 4
    r = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formMove), r)
    counted r.head == 8
    r = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formMove), r)
    counted r.head == 11        # the next LOGICAL line, reached by a DISPLAY step
    r = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formMove), r)
    counted r.head == 11        # clamped at the last row — specified behaviour

  test "SCREEN-LINE `$` LANDS ON THE LAST CHARACTER OF A CONTINUING ROW, NOT PAST IT":
    # Measured rather than reasoned about: with `$` returning the row's width,
    # the position is the same point as column 0 of the NEXT row, so `g$`
    # reported the following row and nine of the twelve motion cells went red.
    let doc = "abcdefghij"
    let ctx = initDisplayCtx(doc, wrapSettings(4, 4, awNarrow))
    var r = caret(0)
    r = ctx.applyDisplayOp(DisplayOp(motion: dispRowEnd, form: formMove), r)
    counted r.head == 3
    counted ctx.cache.toDisplay(ctx.store.posOf(r.head)).row == 0
    # On the LAST row of a logical line the end-of-text position DOES belong to
    # the row, so `$` reaches it.
    r = caret(8)
    r = ctx.applyDisplayOp(DisplayOp(motion: dispRowEnd, form: formMove), r)
    counted r.head == 10
    # And `0` is the row's first byte, on every row.
    for row in 0 ..< ctx.cache.rowCount:
      let start = ctx.cache.toLogical(DisplayPos(row: row, column: 0))
      var q = caret(ctx.store.offsetOf(start) + 1)
      q = ctx.applyDisplayOp(DisplayOp(motion: dispRowStart, form: formMove), q)
      counted ctx.cache.toDisplay(ctx.store.posOf(q.head)) ==
              DisplayPos(row: row, column: 0)

  test "A DISPLAY MOTION KEEPS THE GOAL COLUMN AND A HORIZONTAL ONE CLEARS IT":
    let doc = "abcdefghij\nz\nabcdefghij"
    let ctx = initDisplayCtx(doc, wrapSettings(4, 4, awNarrow))
    var r = caret(2)
    r = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formMove), r)
    counted r.goalColumn == some(2)
    counted r.head == 6
    r = ctx.applyDisplayOp(DisplayOp(motion: dispRowEnd, form: formMove), r)
    counted r.goalColumn.isNone

  test "THE GOAL SURVIVES A NARROW ROW — the reason `goalColumn` is a field":
    # A row of width 1 between two wide ones. A goal recomputed from the landed
    # column collapses to 1 and never comes back.
    let doc = "abcdefgh\nz\nabcdefgh"
    let ctx = initDisplayCtx(doc, wrapSettings(80, 4, awNarrow))
    var r = caret(5)
    counted ctx.cache.toDisplay(ctx.store.posOf(r.head)).column == 5
    r = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formMove), r)
    counted r.head == 10          # clamped onto the one-character line
    counted r.goalColumn == some(5)
    r = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formMove), r)
    counted ctx.cache.toDisplay(ctx.store.posOf(r.head)).column == 5

  test "GOAL COLUMNS ARE COLUMNS, NOT CLUSTER INDICES — a CJK line proves the difference":
    let doc = "漢字漢字\nabcdefgh"
    let ctx = initDisplayCtx(doc, wrapSettings(80, 4, awNarrow))
    counted ctx.cache.metricsOf(0).width == 8
    counted ctx.cache.metricsOf(0).clusters.len == 4
    var r = caret(6)                       # the third ideograph, column 4
    counted ctx.cache.toDisplay(ctx.store.posOf(r.head)).column == 4
    r = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formMove), r)
    # Line 1 starts at document offset 13. A cluster-index goal would land at
    # its byte 2 — offset 15, because the caret was the third CLUSTER; a COLUMN
    # goal lands at its byte 4, offset 17, because the caret was at column 4.
    counted ctx.store.offsetOf(textPos(1, 0)) == 13
    counted r.head == 17
    counted ctx.cache.toDisplay(ctx.store.posOf(r.head)).column == 4

  test "the three forms differ, and they differ in the way Vim's three modes do":
    let doc = "abcdefghij"
    let ctx = initDisplayCtx(doc, wrapSettings(4, 4, awNarrow))
    let start = spanRange(1, 3)
    let m = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formMove), start)
    let e = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formExtend), start)
    let s = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formSpan), start)
    counted m.isEmpty
    counted m.head == 7
    counted e.anchor == 1
    counted e.head == 7
    counted s.rangeFrom == 3
    counted s.head == 7
    counted DisplayOpCount == 12

  test "THE GUTTER FACTS ARE FACTS, AND WHICH ROW CARRIES A NUMBER IS NOT ONE OF THEM":
    let doc = "abcdefghij\nz\n"
    let c = initWrapCache(doc, wrapSettings(4, 4, awNarrow))
    counted c.rowCount == 5
    counted c.gutterFacts(0) == GutterFacts(line: 0, rowInLine: 0, rowsInLine: 3,
                                            isContinuation: false)
    counted c.gutterFacts(1).isContinuation
    counted c.gutterFacts(2).rowInLine == 2
    counted c.gutterFacts(3) == GutterFacts(line: 1, rowInLine: 0, rowsInLine: 1,
                                            isContinuation: false)
    # A wrapped logical line has ONE gutter entry and several display rows —
    # §9's sentence, executable. The model states the counts; the renderer
    # decides which row shows the number.
    var firstRows = 0
    for i in 0 ..< c.rowCount:
      if not c.gutterFacts(i).isContinuation: inc firstRows
    counted firstRows == c.lineCount

  test "MULTI-CURSOR NEEDS NO SPECIAL CASE IN DISPLAY SPACE EITHER":
    let doc = "abcdefghij\nklmnopqrst"
    let ctx = initDisplayCtx(doc, wrapSettings(4, 4, awNarrow))
    let sel = editorSelection([caret(1), caret(6), caret(13)], 1)
    counted sel.rangeCount == 3
    let moved = ctx.runDisplayOp(
      DisplayOp(motion: dispRowDown, form: formMove), sel)
    counted moved.rangeCount == 3
    counted moved.primaryIndex == 1
    counted moved.ranges.mapIt(it.head) == @[5, 10, 17]
    counted moved.invariantViolation.len == 0

suite "PLAT-27 — the examples' tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
