## PLAT-26 — the worked examples, the real-stack integration tests, and the
## two column conversions checked against an independent oracle.
##
## Subjects: `viewmodel/editor/selection.nim`, `viewmodel/editor/selection_ops.nim`
## and `viewmodel/editor/transaction.nim`.
##
## =========================================================================
## WHY THERE ARE EXAMPLES BESIDE LAWS
## =========================================================================
##
## Editor-Model-Conformance-Suite.md §2: a law quantified over a generated
## population tells you the property holds; it does not tell you the property
## is the one you meant. Every case below is a pinned answer somebody can read
## and disagree with — the merge of two touching ranges, the caret that shrinks
## away from a remote insert at its anchor, the column a tab lands on.
##
## **NO MOCKS.** The documents are the real Unicode corpus and the real
## `TextStore` (a rope); the change sets are real `ChangeSet`s; the merge path
## is the real `mergeTransactions`, which goes through the real `rebase`. The
## milestone's *"Real-stack integration tests (no mocks)"* section names two,
## and both are here: vertical motion through alternating line lengths, and the
## three concurrent-edit boundary cases.
##
## =========================================================================
## THE COLUMN ORACLE IS NOT THIS MODULE'S OWN CODE
## =========================================================================
##
## `columnAt` is checked against `unicode_corpus.expandTabs`, which PLAT-24
## wrote to verify the corpus manifest and which walks the line summing every
## cluster's width. That is a second, independent walk — the manifest's own
## oracle — and the two agreeing over all eighteen corpus documents, line by
## line, is a stronger statement than either alone. §30 asks that a RULE and
## its CONTROL not be the same function; this is the shape that satisfies it.

import std/[options, strutils, unittest]

import ../../editor/change_set
import ../../editor/selection
import ../../editor/selection_ops
import ../../editor/text_store
import ../../editor/transaction
import ../corpus/unicode_corpus

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 249
  ## Asserted by the last case against the runtime tally.

const LadderTabSize = 4

# ===========================================================================
# THE RANGE — a variant over emptiness
# ===========================================================================

suite "PLAT-26 — the range is a variant, and each field is where it means something":

  test "a caret and a span are two arms, and the constructor decides which":
    # `spanRange` is the one constructor a motion calls, and `anchor == head`
    # yields a CARET rather than a zero-length span. A motion that happens to
    # collapse a selection therefore does not have to notice.
    let c = spanRange(5, 5)
    counted c.kind == srEmpty
    counted c.isEmpty
    counted c.pos == 5
    counted c.anchor == 5 and c.head == 5
    counted c.byteLen == 0
    let s = spanRange(3, 9)
    counted s.kind == srNonEmpty
    counted not s.isEmpty
    counted s.lo == 3 and s.hi == 9
    counted not s.inverted
    counted s.anchor == 3 and s.head == 9
    counted s.byteLen == 6

  test "DIRECTION IS A FIELD, because extend-style motions need it":
    # A range that knew only `lo` and `hi` could not tell a rightward selection
    # from a leftward one, and `extend-left` would grow one and shrink the
    # other identically. That is the whole reason `inverted` exists — and it
    # exists ONLY on the non-empty arm, because a caret has no direction.
    let right = spanRange(3, 9)
    let left = spanRange(9, 3)
    counted right.rangeFrom == left.rangeFrom
    counted right.rangeTo == left.rangeTo
    counted right.head == 9 and left.head == 3
    counted right.anchor == 3 and left.anchor == 9
    counted not right.inverted
    counted left.inverted
    counted right != left
    # And the two behave differently under a real extend, which is the point.
    let ctx = initOpCtx("abcdefghij")
    let grown = applyRangeOp(ctx, opExtendLeft, left).range
    let shrunk = applyRangeOp(ctx, opExtendLeft, right).range
    counted grown.head == 2       # the leftward selection GREW
    counted shrunk.head == 8      # the rightward one SHRANK
    counted grown.anchor == 9
    counted shrunk.anchor == 3

  test "association and bidi level exist only on the empty arm; goal on both":
    # CodeMirror packs all four into one integer with `7` for "no bidi level"
    # and `0xffffff` for "no goal column". Here the absences are `none` and
    # `7` is a level like any other.
    let c = caret(4, assocAfter, some(BidiLevel(7)), some(11))
    counted c.assoc == assocAfter
    counted c.bidiLevel == some(BidiLevel(7))
    counted c.goalColumn == some(11)
    let s = spanRange(2, 6, some(11))
    counted s.goalColumn == some(11)
    counted spanRange(2, 6).goalColumn.isNone
    counted caret(4).goalColumn.isNone
    counted caret(4).bidiLevel.isNone

# ===========================================================================
# NORMALISATION — worked examples
# ===========================================================================

suite "PLAT-26 — normalisation, with the answers written out":

  test "two touching NON-EMPTY ranges stay two — the merge rule, pinned":
    # `[0,3)` and `[3,6)` abut and do not overlap. They cover disjoint text and
    # are two distinct edit sites, so they survive as two — CodeMirror's rule,
    # Kakoune's rule (`overlaps` is `lhs.max() >= rhs.min()` on inclusive
    # ranges) and Helix's rule, whose own unit test asserts
    # `!overlaps((0, 3), (3, 6))` about this exact pair. The insert two cases
    # below is the measurement that says why it matters.
    let s = editorSelection([spanRange(0, 3), spanRange(3, 6)])
    counted s.rangeCount == 2
    counted s[0].rangeFrom == 0 and s[0].rangeTo == 3
    counted s[1].rangeFrom == 3 and s[1].rangeTo == 6
    counted s.invariantViolation.len == 0
    # A ONE-BYTE GAP is the same answer, so "abutting survives" is not an
    # artefact of the gap.
    let t = editorSelection([spanRange(0, 3), spanRange(4, 6)])
    counted t.rangeCount == 2
    # AND STRICT OVERLAP STILL MERGES, or "keep touching ranges" would have
    # become "keep everything".
    let u = editorSelection([spanRange(0, 4), spanRange(3, 6)])
    counted u.rangeCount == 1
    counted u[0].rangeFrom == 0 and u[0].rangeTo == 6

  test "a touching pair merges when EITHER of the two is empty":
    # The other side of the rule, and the reason it is not "merge only on
    # overlap": an empty range has no extent, so absorbing it destroys nothing
    # and leaves no distinct edit site behind. Both edges are checked, because
    # CodeMirror keys its `<=` on the emptiness of the INCOMING range alone and
    # therefore answers these two differently depending on the sort's
    # tie-break; here the test is symmetric.
    let atEnd = editorSelection([spanRange(0, 4), caret(4)])
    counted atEnd.rangeCount == 1
    counted not atEnd[0].isEmpty
    counted atEnd[0].rangeFrom == 0 and atEnd[0].rangeTo == 4
    let atStart = editorSelection([caret(0), spanRange(0, 4)])
    counted atStart.rangeCount == 1
    counted not atStart[0].isEmpty
    counted atStart[0].rangeFrom == 0 and atStart[0].rangeTo == 4
    # TWO CARETS AT ONE OFFSET ARE ONE CURSOR — the case that makes
    # "merge only on overlap" wrong on its own, since a point overlaps nothing.
    let coincident = editorSelection([caret(3), caret(3)])
    counted coincident.rangeCount == 1
    # AND A CARET ONE BYTE OFF THE EDGE IS NOT ABSORBED.
    let apart = editorSelection([spanRange(0, 4), caret(5)])
    counted apart.rangeCount == 2

  test "the primary follows its range across a merge that is NOT the last one":
    # **A DEFECT THIS SHAPE FOUND**, recorded as a case because a clamp used to
    # hide it. The primary index was tracked by decrementing it once per merge
    # at or before it — correct in CodeMirror, which splices the live array, and
    # wrong here, where the loop index addresses the SORTED input while the
    # index being decremented addresses the MERGED output. The two drift apart
    # after the first merge.
    #
    # It needs a merged GROUP followed by a SURVIVING range to show: otherwise
    # the wrong index runs off the end and an `if mainIndex >= merged.len`
    # clamp puts it back on the only range there is, and every wrong answer
    # looks right. That clamp is gone; it raises now.
    #
    # Here the group is `caret(0)`, `[0,2)` and `caret(2)` — three ranges that
    # merge into `[0,2)` — followed by `caret(8)`, which does not.
    let rs = @[spanRange(0, 2), caret(2), caret(0), caret(8)]
    for p in 0 ..< rs.len:
      let s = editorSelection(rs, p)
      counted s.rangeCount == 2
      # LAW-S2's property, at each of the four placements: the surviving
      # primary contains the head the pre-normalisation primary had.
      let head = rs[p].head
      checkpoint("primary " & $p & " head " & $head & " -> " & $s)
      counted s.mainRange.rangeFrom <= head
      counted head <= s.mainRange.rangeTo
    # And named exactly, so a future regression says which way it went: the
    # three that merge land on range 0, the far caret lands on range 1.
    counted editorSelection(rs, 0).primaryIndex == 0
    counted editorSelection(rs, 1).primaryIndex == 0
    counted editorSelection(rs, 2).primaryIndex == 0
    counted editorSelection(rs, 3).primaryIndex == 1

  test "unsorted input comes back sorted, and the primary follows its range":
    let s = editorSelection([spanRange(20, 24), spanRange(0, 4), spanRange(10, 14)],
                            primary = 0)
    counted s.rangeCount == 3
    counted s[0].rangeFrom == 0
    counted s[1].rangeFrom == 10
    counted s[2].rangeFrom == 20
    # The primary was the range at 20, and it is index 2 now — not index 0,
    # which is what "reset the primary index to 0" (LAW-S2's killer) would give.
    counted s.primaryIndex == 2
    counted s.mainRange.rangeFrom == 20

  test "the primary lands on the range that ABSORBED it":
    # Three overlapping ranges collapse to one; whichever was primary, the
    # single survivor is primary and it contains the old head.
    for p in 0 .. 2:
      let s = editorSelection([spanRange(0, 5), spanRange(3, 8), spanRange(6, 11)],
                              primary = p)
      counted s.rangeCount == 1
      counted s.primaryIndex == 0
      counted s[0].rangeFrom == 0 and s[0].rangeTo == 11

  test "duplicates collapse and the direction of the last one wins":
    let s = editorSelection([spanRange(2, 6), spanRange(6, 2)])
    counted s.rangeCount == 1
    counted s[0].rangeFrom == 2 and s[0].rangeTo == 6
    counted s[0].inverted           # the INCOMING range's direction
    let t = editorSelection([spanRange(6, 2), spanRange(2, 6)])
    counted t.rangeCount == 1
    counted not t[0].inverted

  test "a caret on a range's edge is absorbed, and two coincident carets become one":
    let s = editorSelection([spanRange(4, 9), caret(9)])
    counted s.rangeCount == 1
    counted s[0].rangeFrom == 4 and s[0].rangeTo == 9
    counted not s[0].isEmpty
    let t = editorSelection([caret(3), caret(3)])
    counted t.rangeCount == 1
    counted t[0].isEmpty
    counted t[0].pos == 3

  test "a selection cannot be built empty, and an out-of-range primary is refused":
    # §7: a selection is a NON-EMPTY sequence. Both refusals are by name rather
    # than by returning something plausible.
    var raised = 0
    try: discard editorSelection([])
    except SelectionError: inc raised
    try: discard editorSelection([caret(0)], primary = 3)
    except SelectionError: inc raised
    counted raised == 2
    counted caretSelection(7).rangeCount == 1
    counted caretSelection(7).mainRange.pos == 7

  test "THE ZERO VALUE IS REACHABLE, IT IS NOT LEGAL, AND IT IS INERT BY NAME":
    # **The claim the type enforces, written out, because the claim the spec
    # used to make was stronger than the type.** "Normalisation cannot be
    # skipped" is true — the fields are private and `editorSelection` is the
    # only constructor. "Un-normalised is unrepresentable" is NOT: the zero
    # value is reachable from three directions and holds no ranges.
    #
    # It stays illegal rather than being made a legal "no cursor" state,
    # because §7 has no such state: a caret is a range, one cursor is a set of
    # one, and "where does the next keystroke go" must have an answer. So every
    # door out of it refuses BY NAME. `mainRange` used to raise `IndexDefect`
    # — a message about a sequence index rather than about the value the caller
    # is holding — and that was the one leak.
    var viaVar: EditorSelection
    let viaDefault = default(EditorSelection)
    var viaReset = caretSelection(4)
    reset(viaReset)
    for z in [viaVar, viaDefault, viaReset]:
      counted z.rangeCount == 0
      counted not z.isNormalised
      counted z.invariantViolation.len > 0
      counted z.ranges.len == 0
      var iterated = 0
      for r in z: inc iterated
      counted iterated == 0
      var refusals = 0
      try: discard z.mainRange
      except SelectionError: inc refusals
      try: discard z[0]
      except SelectionError: inc refusals
      try: discard mapSelection(z, changeSet(10, 2, 2, "ab"))
      except SelectionError: inc refusals
      try: discard changeByRange("0123456789", z,
        proc (r: SelectionRange): RangeOutcome =
          RangeOutcome(edits: @[], range: r, effects: @[]))
      except SelectionError: inc refusals
      counted refusals == 4
    # AND THE SAME CALLS ON A REAL SELECTION DO NOT REFUSE, or "it raises" would
    # be a statement about a function that always raises.
    let real = caretSelection(4)
    counted real.mainRange.pos == 4
    counted real[0].pos == 4
    counted mapSelection(real, changeSet(10, 2, 2, "ab")).rangeCount == 1
    counted real.isNormalised

# ===========================================================================
# MULTI-CURSOR IS THE ABSENCE OF A SPECIAL CASE
# ===========================================================================

suite "PLAT-26 — one cursor is a set of one":

  test "typing at three carets inserts three times, through ONE code path":
    let ctx = initOpCtx("alpha beta gamma", inserted = "->")
    let three = editorSelection([caret(0), caret(6), caret(11)], primary = 1)
    let (doc, sel) = applyOp(ctx, opInsertText, three)
    counted doc == "->alpha ->beta ->gamma"
    counted sel.rangeCount == 3
    counted sel[0].pos == 2
    counted sel[1].pos == 10
    counted sel[2].pos == 17
    counted sel.primaryIndex == 1
    # AND THE SAME CODE PATH WITH ONE CARET. If multi-cursor needed a special
    # case there would be a branch here; there is not, and this is the
    # executable form of that sentence.
    let one = caretSelection(6)
    let (doc1, sel1) = applyOp(ctx, opInsertText, one)
    counted doc1 == "alpha ->beta gamma"
    counted sel1.rangeCount == 1
    counted sel1[0].pos == 8

  test "TWO ABUTTING SELECTIONS PRODUCE TWO INSERTIONS — the measurement":
    # **THE CASE THE MERGE RULE WAS DECIDED ON.** An earlier version of
    # `editorSelection` merged ranges that merely touch, on the stated grounds
    # that two abutting selections are "behaviourally indistinguishable to a
    # user". They render alike, the ten motions agree and `delete` agrees — and
    # an INSERT does not, which is the one operation multi-cursor exists for.
    #
    # Under "merge on touch" this case reads `"Xghij"` with ONE range. It is
    # the red half of Verification-Harness-Traps §36's second rule: *"moving
    # the design costs nothing" is itself a claim needing a measurement.*
    let ctx = initOpCtx("abcdefghij", inserted = "X")
    let two = editorSelection([spanRange(0, 3), spanRange(3, 6)])
    counted two.rangeCount == 2
    let (doc, sel) = applyOp(ctx, opInsertText, two)
    counted doc == "XXghij"
    counted sel.rangeCount == 2
    counted sel[0].pos == 1
    counted sel[1].pos == 2
    # AND THE MERGED RANGE IS THE OTHER ANSWER, spelled out beside it rather
    # than described — `[0,6)` is what the rejected rule would have produced,
    # and it inserts once.
    let merged = editorSelection([spanRange(0, 6)])
    counted merged.rangeCount == 1
    counted applyOp(ctx, opInsertText, merged)[0] == "Xghij"
    counted applyOp(ctx, opInsertText, merged)[0] != doc
    # `delete` agrees either way, which is why the divergence was missed: an
    # operation set swept for agreement would have reported none.
    counted applyOp(ctx, opDeleteRange, two)[0] ==
            applyOp(ctx, opDeleteRange, merged)[0]
    counted applyOp(ctx, opDeleteRange, two)[0] == "ghij"

  test "EXTENDING TWO SELECTIONS INTO CONTACT does not cost a cursor":
    # The reachability half. Nothing here constructs an abutting pair: it
    # starts from an ordinary two-cursor selection with a gap and walks it into
    # contact with the primitive a user actually presses.
    #
    # `[0,2)` and `[4,6)`, two `extend-right` steps each, give `[0,4)` and
    # `[4,8)`. Under "merge on touch" the second step silently drops a cursor
    # and the count here is 1.
    let ctx = initOpCtx("abcdefghij", inserted = "X")
    var sel = editorSelection([spanRange(0, 2), spanRange(4, 6)])
    counted sel.rangeCount == 2
    sel = applyOp(ctx, opExtendRight, sel)[1]
    counted sel.rangeCount == 2
    counted sel[0].rangeTo == 3 and sel[1].rangeFrom == 4
    sel = applyOp(ctx, opExtendRight, sel)[1]
    # THE STEP THAT BRINGS THEM INTO CONTACT.
    counted sel.rangeCount == 2
    counted sel[0].rangeFrom == 0 and sel[0].rangeTo == 4
    counted sel[1].rangeFrom == 4 and sel[1].rangeTo == 8
    counted sel[0].rangeTo == sel[1].rangeFrom
    # The anchors did not move, so these really are two extended selections and
    # not two ranges that happen to line up.
    counted sel[0].anchor == 0 and sel[0].head == 4
    counted sel[1].anchor == 4 and sel[1].head == 8
    # AND THE CURSOR IS STILL THERE WHERE IT COUNTS: two insertions.
    counted applyOp(ctx, opInsertText, sel)[0] == "XXij"
    # ONE MORE STEP AND THEY DO MERGE, which is the other side of the rule:
    # both heads advance, so the first range's head moves PAST the second's
    # start and the two genuinely overlap. Contact is kept, overlap is not.
    sel = applyOp(ctx, opExtendRight, sel)[1]
    counted sel.rangeCount == 1
    counted sel[0].rangeFrom == 0 and sel[0].rangeTo == 9

  test "an operator consumes whatever a motion produced, and does not know which":
    # Kakoune's argument, executable: `opDeleteRange` is written once, over one
    # range, and never asks how the range was selected. Two different motions
    # feed it and the operator's code path is the same.
    let ctx = initOpCtx("one\ntwo three\nfour")
    let viaLine = block:
      let (_, s) = applyOp(ctx, opSelectLine, caretSelection(6))
      applyOp(ctx, opDeleteRange, s)
    counted viaLine[0] == "one\n\nfour"
    let viaExtend = block:
      var s = caretSelection(4)
      for i in 0 ..< 9: s = applyOp(ctx, opExtendRight, s)[1]
      applyOp(ctx, opDeleteRange, s)
    counted viaExtend[0] == "one\n\nfour"
    # Same document, two vocabularies, one operator — which is what a FUSED
    # `delete-line` would have made two implementations of.
    counted viaLine[0] == viaExtend[0]

  test "`changeByRange` returns one change set, one selection and one effect list":
    # §7's fifth deliverable. The effect list is mapped too, and by the arm
    # that belongs to it: a range's effects move over the OTHER ranges' changes
    # and vice versa.
    let doc = "0123456789"
    let sel = editorSelection([caret(2), caret(7)])
    let t = changeByRange(doc, sel, proc (r: SelectionRange): RangeOutcome =
      RangeOutcome(
        edits: @[Edit(fromPos: r.rangeFrom, toPos: r.rangeTo, insert: "**")],
        range: caret(r.rangeFrom + 2),
        effects: @[Effect(kind: efMoveCaretTo, caret: r.rangeFrom)]))
    counted t.changes.apply(doc) == "01**23456**789"
    counted t.selection.get.rangeCount == 2
    counted t.selection.get[0].pos == 4
    counted t.selection.get[1].pos == 11
    counted t.effects.len == 2
    counted t.effects[0].kind == efMoveCaretTo
    # The first range's effect was at 2 and stays at 2 — the second range's
    # insert is after it. The second was at 7 and moves to 9, over the first
    # range's two inserted bytes.
    counted t.effects[0].caret == 2
    counted t.effects[1].caret == 9

  test "deleting at K carets and at one caret agree on the single-caret case":
    let ctx = initOpCtx("abcdef")
    let (d1, s1) = applyOp(ctx, opDeleteRange, caretSelection(3))
    counted d1 == "abdef"
    counted s1.rangeCount == 1
    counted s1[0].pos == 2
    let (d3, s3) = applyOp(ctx, opDeleteRange,
                           editorSelection([caret(1), caret(3), caret(5)]))
    counted d3 == "bdf"
    counted s3.rangeCount == 3
    counted s3[0].pos == 0
    counted s3[1].pos == 1
    counted s3[2].pos == 2

# ===========================================================================
# REAL-STACK INTEGRATION TEST 1 — vertical motion, alternating line lengths
# ===========================================================================

suite "PLAT-26 — vertical motion through alternating line lengths":

  test "the column does not collapse — three down, three up, over a real rope":
    # The milestone's first named integration test, and the property the goal
    # column exists for. The document is nine lines alternating a twelve-cell
    # line with a three-cell one; the caret starts at column 9 of line 0.
    let long = "abcdefghijkl"
    let short = "xyz"
    var lines: seq[string] = @[]
    for i in 0 ..< 9:
      lines.add(if i mod 2 == 0: long else: short)
    let ctx = initOpCtx(lines.join("\n"))
    counted ctx.store.lineCount == 9
    var sel = caretSelection(9)
    counted sel.mainRange.goalColumn.isNone
    var columns: seq[int] = @[]
    for step in 1 .. 3:
      sel = applyOp(ctx, opMoveLineDown, sel)[1]
      let line = ctx.store.posOf(sel.mainRange.head).line
      columns.add columnAt(ctx.store.lineText(line),
                           sel.mainRange.head - ctx.store.offsetOf(textPos(line, 0)))
      # THE GOAL IS CARRIED, not re-derived. This is the field whose absence
      # is the collapse.
      counted sel.mainRange.goalColumn == some(9)
    # The odd lines are three cells wide, so the landing column there is 3 and
    # not 9 — which is what makes the return trip a statement.
    counted columns == @[3, 9, 3]
    for step in 1 .. 3:
      sel = applyOp(ctx, opMoveLineUp, sel)[1]
    counted ctx.store.posOf(sel.mainRange.head).line == 0
    counted sel.mainRange.head == 9
    counted sel.mainRange.goalColumn == some(9)

  test "a HORIZONTAL motion clears the goal, so the next descent starts fresh":
    # The other half of the rule, and without it LAW-S5 would be a law about
    # motion in general rather than about vertical motion.
    let ctx = initOpCtx("abcdefghijkl\nxyz\nabcdefghijkl")
    var sel = applyOp(ctx, opMoveLineDown, caretSelection(9))[1]
    counted sel.mainRange.goalColumn == some(9)
    sel = applyOp(ctx, opMoveLeft, sel)[1]
    counted sel.mainRange.goalColumn.isNone
    sel = applyOp(ctx, opMoveLineDown, sel)[1]
    # The goal is now taken from where the caret actually is, which is column 2
    # of the three-cell line.
    counted sel.mainRange.goalColumn == some(2)

  test "the goal column is a DISPLAY column: a tab and a wide glyph prove it":
    # A goal column that counted CLUSTERS would be right on ASCII and wrong
    # here, which is §4.3's reason for running LAW-S5 over the corpus.
    let ctx = initOpCtx("\tab\n漢字漢字\nqrstuvwx")
    let policy = ColumnPolicy(tabSize: LadderTabSize, ambiguous: awNarrow)
    counted columnAt("\tab", 1, policy) == LadderTabSize
    counted columnAt("\tab", 3, policy) == LadderTabSize + 2
    counted columnAt("漢字漢字", 6, policy) == 4       # two ideographs, four cells
    counted lineWidth("漢字漢字", policy) == 8
    counted lineWidth("\tab", policy) == LadderTabSize + 2
    # And a descent from column 4 of the tab line lands on the second
    # ideograph's START, not inside it.
    var sel = caretSelection(1)                        # just after the tab
    sel = applyOp(ctx, opMoveLineDown, sel)[1]
    counted sel.mainRange.goalColumn == some(4)
    counted sel.mainRange.head == ctx.store.offsetOf(textPos(1, 6))
    counted sel.mainRange.head in ctx.boundaries

  test "`offsetAtColumn` never lands inside a cluster, at any column of any width":
    # The defect the corpus exists to catch, asserted directly rather than as a
    # consequence of a motion.
    let line = "a漢b字c"
    var checkedCols = 0
    for col in 0 .. lineWidth(line) + 2:
      let off = offsetAtColumn(line, col)
      counted off in clusterBoundariesOf(line)
      inc checkedCols
    counted checkedCols == lineWidth(line) + 3
    counted offsetAtColumn(line, 0) == 0
    counted offsetAtColumn(line, 1) == 1     # after "a", before 漢
    counted offsetAtColumn(line, 2) == 1     # INSIDE 漢's two cells: its start
    counted offsetAtColumn(line, 3) == 4     # after 漢

# ===========================================================================
# REAL-STACK INTEGRATION TEST 2 — the concurrent-edit boundary cases
# ===========================================================================

suite "PLAT-26 — concurrent edits exactly at a boundary":

  test "an insert exactly at the ANCHOR does not grow the selection":
    let doc = "0123456789"
    let sel = singleSelection(4, 8)            # anchor 4, head 8
    let remote = changeSet(doc.len, 4, 4, "##")
    let moved = mapSelection(sel, remote)
    counted moved.rangeCount == 1
    counted moved[0].anchor == 6               # the anchor moved off the insert
    counted moved[0].head == 10
    counted moved[0].byteLen == sel[0].byteLen
    counted remote.apply(doc) == "0123##456789"

  test "an insert exactly at the HEAD does not grow the selection":
    let doc = "0123456789"
    let sel = singleSelection(4, 8)
    let remote = changeSet(doc.len, 8, 8, "##")
    let moved = mapSelection(sel, remote)
    counted moved[0].anchor == 4
    counted moved[0].head == 8                 # the head stayed before it
    counted moved[0].byteLen == sel[0].byteLen
    # The same insert, with the selection the OTHER way round, is the same
    # answer — the bias is a property of the two ENDS, not of the direction.
    let flipped = mapSelection(singleSelection(8, 4), remote)
    counted flipped[0].rangeFrom == 4
    counted flipped[0].rangeTo == 8
    counted flipped[0].inverted

  test "an insert at BOTH ends of an EMPTY range, where association decides":
    # A caret has one position and no edges, so there is nothing to shrink away
    # from: the association is the whole answer, and this is the case that says
    # so. Both arms are taken.
    let doc = "0123456789"
    let remote = changeSet(doc.len, 5, 5, "##")
    let before = mapRange(caret(5, assocBefore), remote)
    let after = mapRange(caret(5, assocAfter), remote)
    counted before.pos == 5
    counted after.pos == 7
    counted before.assoc == assocBefore
    counted after.assoc == assocAfter
    # A range that COLLAPSES under a deletion becomes a caret at the collapse
    # point rather than an inverted pair of offsets.
    let wipe = changeSet(doc.len, 3, 9, "")
    let gone = mapRange(spanRange(4, 8), wipe)
    counted gone.isEmpty
    counted gone.pos == 3

  test "a concurrent merge carries a K-range selection through the ONE primitive":
    # The real `mergeTransactions`, which calls the real `rebase`. Until
    # PLAT-26 the selection it carried was one anchor and one head; now it is
    # §7's set, and a K-range selection survives a concurrent merge.
    let doc = "0123456789"
    let a = transaction(changeSet(10, 2, 2, "ab"),
                        some(editorSelection([caret(2), caret(9)])))
    let b = transaction(changeSet(10, 6, 8, "Z"),
                        some(editorSelection([caret(1), caret(7)])))
    let m = mergeTransactions(a, b, sequential = false)
    let r = rebase(a.changes, b.changes)
    counted m.changes == compose(a.changes, r.bOverA)
    counted m.changes.apply(doc) == "01ab2345Z89"
    counted m.selection.get.rangeCount == 2
    # `b`'s selection wins and is mapped through `aOverB` — over `a`'s two
    # inserted bytes at 2.
    counted m.selection.get[0].pos == 1
    counted m.selection.get[1].pos == 9

  test "mapping a selection never produces MORE ranges — the two-edit case":
    # LAW-S6's killer is "emit one mapped range per touched change section, so
    # a range spanning two edits comes back as two". Here is a range spanning
    # two edits; it comes back as ONE.
    let doc = "0123456789"
    let cs = changeSet(doc.len, [Edit(fromPos: 3, toPos: 4, insert: "XXX"),
                                 Edit(fromPos: 6, toPos: 7, insert: "YYY")])
    counted cs.changedRangeSeq(individual = true).len == 2
    let moved = mapSelection(singleSelection(2, 9), cs)
    counted moved.rangeCount == 1
    counted moved[0].rangeFrom == 2
    counted moved[0].rangeTo == 13
    counted cs.apply(doc) == "012XXX45YYY789"

# ===========================================================================
# THE COLUMN CONVERSIONS, AGAINST AN INDEPENDENT ORACLE
# ===========================================================================

suite "PLAT-26 — the two column conversions over the whole corpus":

  test "`columnAt` at a line's end agrees with the corpus manifest's own walk":
    # `expandTabs` is PLAT-24's, written to verify the manifest, and it is a
    # different walk of the same definition. Over all eighteen documents, line
    # by line, at BOTH ambiguous-width settings.
    var lines = 0
    var disagreements = 0
    var wideLines = 0
    for amb in [awNarrow, awWide]:
      let policy = ColumnPolicy(tabSize: LadderTabSize, ambiguous: amb)
      for d in CorpusDocs:
        for line in d.text.split('\n'):
          inc lines
          let mine = columnAt(line, line.len, policy)
          let theirs = expandTabs(line, LadderTabSize, amb)
          if mine != theirs:
            inc disagreements
            if disagreements < 4:
              checkpoint(d.id & ": " & $mine & " vs " & $theirs)
          if mine != line.len: inc wideLines
    counted lines > 200
    counted disagreements == 0
    # AND THE ORACLE IS NOT TRIVIALLY SATISFIED: some lines' display width
    # differs from their byte length, or "two walks agree" would be two walks
    # counting bytes.
    counted wideLines > 0

  test "the ambiguous-width policy is a PARAMETER, and it is two-sided":
    # LAW-C5's shape, one milestone early: switching the policy must change the
    # answer for a document in the ambiguous class and must NOT change it for
    # an ASCII one. A version that ignored the parameter passes only the second
    # half, which is why the second half is here.
    var changed = 0
    var unchanged = 0
    for d in docsOfClass(4):            # the ambiguous-width class
      for line in d.text.split('\n'):
        if columnAt(line, line.len, ColumnPolicy(tabSize: 4, ambiguous: awNarrow)) !=
           columnAt(line, line.len, ColumnPolicy(tabSize: 4, ambiguous: awWide)):
          inc changed
    for d in docsOfClass(9):            # the ASCII control class
      for line in d.text.split('\n'):
        if columnAt(line, line.len, ColumnPolicy(tabSize: 4, ambiguous: awNarrow)) ==
           columnAt(line, line.len, ColumnPolicy(tabSize: 4, ambiguous: awWide)):
          inc unchanged
    counted changed > 0
    counted unchanged > 0

  test "the round trip is exact in COLUMN space and not in OFFSET space, measured":
    # **THE OBVIOUS CLAIM IS FALSE AND THE SUITE SAYS SO RATHER THAN AVOIDING
    # IT.** `offsetAtColumn(line, columnAt(line, b)) == b` reads like a
    # bijection over cluster boundaries, and it is not one: a combining mark is
    # ZERO cells wide, so the boundary before it and the boundary after it
    # occupy the SAME column, and a column cannot name both. Measured over the
    # eighteen corpus documents, line by line: **158,575 of 165,244 boundaries
    # round-trip in offset space and 6,669 do not** — 6,270 displaced FORWARD
    # by a zero-width cluster, and 399 displaced BACKWARD, which is class 7's
    # contribution: `clusterBoundariesOf` appends the line's end when the
    # segmenter stops short of it on a truncated UTF-8 sequence, so that
    # boundary is one the width walk contributes nothing for. All three buckets
    # are counted and their sum is asserted against the total, so there is no
    # fourth state hiding in the difference.
    #
    # What IS exact, and is what a goal column actually needs, is the round
    # trip in COLUMN space: the offset a column resolves to is at that column.
    # So the law is stated over columns, the exception is counted rather than
    # excluded, and the shape of every exception is asserted — a restatement
    # that did not also measure what the obvious wording gets wrong would be a
    # law weakened to fit an implementation.
    let policy = ColumnPolicy(tabSize: LadderTabSize, ambiguous: awNarrow)
    var boundaries = 0
    var offsetRoundTripped = 0
    var zeroWidthShifts = 0
    var illFormedTails = 0
    var columnRoundTripped = 0
    var interiorColumns = 0
    for d in CorpusDocs:
      for line in d.text.split('\n'):
        if line.len == 0 or line.len > 400: continue
        let bs = clusterBoundariesOf(line)
        for b in bs:
          inc boundaries
          let col = columnAt(line, b, policy)
          let back = offsetAtColumn(line, col, policy)
          if back == b: inc offsetRoundTripped
          elif back > b and columnAt(line, back, policy) == col:
            # The clusters between `b` and `back` are all zero-width, so both
            # offsets ARE that column and a column cannot name both.
            inc zeroWidthShifts
          elif back < b and columnAt(line, back, policy) == col:
            # THE OTHER DIRECTION, and it belongs to class 7. `clusterBoundariesOf`
            # appends the line's end when the segmenter stops short of it —
            # which it does on a truncated UTF-8 sequence — so `b` is a
            # boundary the width walk contributes nothing for.
            inc illFormedTails
            if illFormedTails < 4:
              checkpoint("tail: " & d.id & " b=" & $b & " back=" & $back &
                         " len=" & $line.len)
          if columnAt(line, back, policy) == col: inc columnRoundTripped
        for col in 0 .. lineWidth(line, policy):
          if offsetAtColumn(line, col, policy) notin bs: inc interiorColumns
    checkpoint($offsetRoundTripped & " of " & $boundaries &
               " boundaries round-trip in offset space; " & $zeroWidthShifts &
               " are displaced forward by a zero-width cluster and " &
               $illFormedTails & " backward by an ill-formed tail")
    counted boundaries > 500
    # THE LAW, in the space it is true in.
    counted columnRoundTripped == boundaries
    # AND THE EXCEPTION IS FULLY ACCOUNTED FOR: every boundary either
    # round-trips or is displaced onto a same-column neighbour, and nothing is
    # in a third state.
    counted offsetRoundTripped + zeroWidthShifts + illFormedTails == boundaries
    # The exception population is NON-EMPTY, or "measured" would be a word
    # about an empty set — and it is a minority, or the conversion would be
    # useless.
    counted zeroWidthShifts > 0
    counted illFormedTails > 0
    counted zeroWidthShifts * 4 < boundaries
    # Every column resolves to a boundary, which is the half that stops a
    # motion landing inside a glyph.
    counted interiorColumns == 0

# ===========================================================================
# THE TWELVE PRIMITIVES, ONE PINNED ANSWER EACH
# ===========================================================================

suite "PLAT-26 — the twelve primitives, with the answers written out":

  test "every operation has a pinned answer on one document, and all twelve run":
    # A sweep over the enum whose expected values are written here rather than
    # produced by the code under test. `opMoveLineUp` on line 0 and
    # `opMoveLineDown` on the last line are CLAMPS, which is why the document
    # has three lines and the caret starts on the middle one.
    let ctx = initOpCtx("abcd\nefghij\nkl", inserted = "+")
    let start = editorSelection([spanRange(6, 9)])      # "fgh" on line 1
    var ran = 0
    for op in SelectionOp:
      inc ran
      let (doc, sel) = applyOp(ctx, op, start)
      let r = sel.mainRange
      case op
      of opMoveLeft:
        counted doc == ctx.doc and r.isEmpty and r.pos == 8
      of opMoveRight:
        counted doc == ctx.doc and r.isEmpty and r.pos == 10
      of opExtendLeft:
        counted r.anchor == 6 and r.head == 8
      of opExtendRight:
        counted r.anchor == 6 and r.head == 10
      of opMoveLineStart:
        counted r.isEmpty and r.pos == 5
      of opMoveLineEnd:
        counted r.isEmpty and r.pos == 11
      of opMoveLineUp:
        counted r.isEmpty and r.pos == 4 and r.goalColumn == some(4)
      of opMoveLineDown:
        counted r.isEmpty and r.pos == 14 and r.goalColumn == some(4)
      of opCollapseToHead:
        counted r.isEmpty and r.pos == 9
      of opSelectLine:
        counted r.rangeFrom == 5 and r.rangeTo == 11
      of opDeleteRange:
        counted doc == "abcd\neij\nkl" and r.isEmpty and r.pos == 6
      of opInsertText:
        counted doc == "abcd\ne+ij\nkl" and r.isEmpty and r.pos == 7
    counted ran == SelectionOpCount
    counted ran == 12

# ---------------------------------------------------------------------------
# The tally
# ---------------------------------------------------------------------------

suite "PLAT-26 — the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
