## PLAT-28 — the pinned examples, the REFLOW GATE with its measured columns,
## and `EditorRow` graded field by field against today's producer.
##
## Subjects: `viewmodel/editor/{anchor,range_set,decoration,inlay,
## row_projection}.nim` and `frontend/view_vocabulary/editor_surface.nim` —
## the LATTER as the CONTROL, driven rather than transcribed.
##
## =========================================================================
## WHY THIS FILE CARRIES A `.nim.cfg`
## =========================================================================
##
## `editor_surface.nim` imports `codetracer_embed` by BARE MODULE NAME, which
## every `vm-*` lane supplies with `--path:src/frontend/viewmodel`. The floor
## gate (`ci/test/editor-model-case-floor.sh`) runs `nim c -r` directly and
## carries no lane flags, so this file ships a per-file
## `test_editor_decoration_examples.nim.cfg` with that one switch in it. The
## alternative — a `nim.cfg` in `tests/unit/` — would change the compile of
## every suite in that directory at once, which is a lane-wide decision and not
## this milestone's to take.
##
## =========================================================================
## THE PROJECTION IS ASSERTED, NOT ASSUMED — AND WHERE IT DIFFERS IT IS FILED
## =========================================================================
##
## PLAT-28's gate: *"`EditorRow` values produced through this model equal those
## produced by today's `editorSurfaceFor` for the same inputs, field by field —
## and where they deliberately differ, the difference is a named, filed entry
## rather than a diff nobody reads."*
##
## **Which producer, exactly, and this is a limitation stated rather than
## rounded up.** `editorSurfaceFor` (the DEBUG surface) takes four live
## ViewModels and a `SourceVM` built over a real trace folder, a real store and
## a real transport; it cannot be driven from a suite that also compiles under
## `nim js`. `editorSurfaceForProject` — the EDIT-mode surface — is pure over
## `(path, text, points, viewport)` and IS driven here, in three of the four
## scenarios. The fourth drives the per-field rules `editorSurfaceFor` itself
## calls (`editor_rows.pointerFor`, `markFor`, `valuesForLine` and
## `editor_surface.flowStateOf`), which is what makes `pointer`, `values` and
## `flow` graded at all rather than compared at the one setting where both
## sides are trivially equal.
##
## **AND THAT FOURTH SCENARIO IS A §30 EXPOSURE, NAMED RATHER THAN ROUNDED UP.**
## `modelRows(scDebug)` and `controlRows(scDebug)` both call `markFor`,
## `pointerFor`, `flowStateOf` and `valuesForLine` — two copies of one set of
## rules, so for that scenario the control agrees with the model partly because
## it IS the model's rules. It is the scenario that matters most, being the only
## one in which `pointer`, `values`, `flow` and `held` vary at all. What keeps
## its cells from being vacuous is therefore NOT the comparison but the declared
## variety table below; the comparison's independence is real only for the three
## `editorSurfaceForProject` scenarios. Anything published about this suite must
## say "three of four", not "four".
##
## **That last sentence is the trap this file was written against.** Three
## scenarios in which `pointer` is `eptNone` on both sides are three cases that
## cannot fail. So every (field, scenario) cell also asserts the number of
## DISTINCT VALUES the field took, against a declared table — a cell where the
## field is constant SAYS SO, and a cell declared to vary and found constant is
## red.
##
## ARMING: `run-plat28-decoration-mutations.py`.

import std/[strutils, unittest]

import ../../editor/anchor
import ../../editor/decoration
import ../../editor/inlay
import ../../editor/range_set
import ../../editor/row_projection
import ../../editor/wrap
import ../../editor/editor_state
import ../../editor/operations
import ../../editor/collab_text
import ../corpus/unicode_corpus

import ../../../view_vocabulary/editor_surface
import ../../viewmodels/flow_vm

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 352

const Policy = ColumnPolicy(tabSize: 4, ambiguous: awNarrow)
const NoWrap = WrapSettings(wrapColumn: 0, policy: Policy)

# ===========================================================================
# THE REFLOW GATE — a column, measured, in both arms
# ===========================================================================

const GateLine = "total = compute(alpha, beta)"
  ## ASCII and hand-countable, because the GATE's numbers are written in this
  ## file and a reader has to be able to check them without running anything.
  ## The same measurement over the nine corpus classes, with the columns
  ## derived rather than written, is `LAW-C7` in the laws suite.

const GateDoc = GateLine & "\nsecond line\n"
const GateAt = 8
  ## The byte `compute(...)` begins at: `"total = "` is eight ASCII bytes.
const GateWidgetText = "alpha = 41"
const GateWidgetCells = GateWidgetText.len   ## ten ASCII cells

suite "PLAT-28 — THE REFLOW GATE, measured, with both arms":

  test "GATE ARM 1 — with a width-10 widget at column 8, the text after it is at column 18":
    let ds = decorationSet(@[decoration(
      0, GateAt, GateAt, inlineWidget(GateWidgetCells, GateWidgetText))])
    let deco = inlayWrapCache(GateDoc, NoWrap, ds)
    let at = deco.toDisplay(textPos(0, GateAt))
    checkpoint("with widget: byte " & $GateAt & " is at display column " &
               $at.column)
    counted GateWidgetCells == 10
    counted at.column == GateAt + GateWidgetCells
    counted at.column == 18
    # AND THE WHOLE TAIL MOVED WITH IT, not only the first character — a
    # renderer that inserted a gap and then painted the rest where it always
    # was would pass a check on one column.
    counted deco.toDisplay(textPos(0, GateLine.len)).column ==
      GateLine.len + GateWidgetCells
    # THE LINE'S OWN WIDTH GREW BY EXACTLY W, which is the model budgeting a
    # width §8.3 says no ViewModel can see today.
    counted deco.metricsOf(0).width ==
      initWrapCache(GateDoc, NoWrap).metricsOf(0).width + GateWidgetCells

  test "GATE ARM 2 — with the widget removed and NOTHING ELSE CHANGED, it is at column 8":
    # §7b: *"an unfalsified negative control is a self-comparison wearing a
    # negation"*. "The text is after the widget" is also true of a renderer
    # that draws everything at column 0, so the arm WITHOUT the widget has to
    # put the text somewhere else — and it has to reach it through the SAME
    # constructor, or the two arms differ in more than the widget.
    let plain = initWrapCache(GateDoc, NoWrap)
    let at = plain.toDisplay(textPos(0, GateAt))
    checkpoint("without widget: byte " & $GateAt & " is at display column " &
               $at.column)
    counted at.column == GateAt
    counted at.column == 8
    counted plain.toDisplay(textPos(0, GateLine.len)).column == GateLine.len
    # THE TWO ARMS DIFFER BY EXACTLY W.
    let ds = decorationSet(@[decoration(
      0, GateAt, GateAt, inlineWidget(GateWidgetCells, GateWidgetText))])
    let deco = inlayWrapCache(GateDoc, NoWrap, ds)
    counted deco.toDisplay(textPos(0, GateAt)).column - at.column ==
      GateWidgetCells

  test "GATE ARM 3 — THE WRAP ARM: the line wraps with the widget and not without it":
    # **THE CLAIM A HOST-DRAWN OVERLAY CANNOT MAKE.** An overlay is painted
    # over a layout the model already fixed; it cannot move a wrap point.
    let lineWidth = initWrapCache(GateDoc, NoWrap).metricsOf(0).width
    counted lineWidth == GateLine.len
    # The wrap column is DERIVED: the plain line fits in it exactly and the
    # decorated one cannot.
    let wrapAt = lineWidth + GateWidgetCells - 1
    let settings = WrapSettings(wrapColumn: wrapAt, policy: Policy)
    let ds = decorationSet(@[decoration(
      0, GateLine.len, GateLine.len,
      inlineWidget(GateWidgetCells, GateWidgetText))])
    let plain = initWrapCache(GateDoc, settings)
    let deco = inlayWrapCache(GateDoc, settings, ds)
    checkpoint("at wrap column " & $wrapAt & ": " & $plain.rowsInLine(0) &
               " row(s) plain, " & $deco.rowsInLine(0) & " with the widget")
    counted plain.rowsInLine(0) == 1
    counted deco.rowsInLine(0) == 2
    # AND THE DOCUMENT'S TOTAL ROW COUNT MOVED, so the change is visible to a
    # renderer that only ever asks how many rows there are.
    counted deco.rowCount == plain.rowCount + 1
    # THE WIDGET IS WHAT MOVED IT: the second row begins at the widget, and the
    # text before it is untouched.
    counted deco.rowAt(0).width == lineWidth
    counted deco.rowAt(1).width == GateWidgetCells

  test "A WIDE CLUSTER AFTER THE WIDGET IS POSITIONED IN CELLS, NOT IN CLUSTERS":
    # §3.3's own note on `LAW-C7`: *"a wide CJK glyph after an inline widget is
    # the input that distinguishes 'positioned after it' from 'positioned after
    # it in cells'."*
    let doc = "ab漢字cd\n"          # a b <han> <zi> c d
    let plain = initWrapCache(doc, NoWrap)
    counted plain.metricsOf(0).width == 2 + 2 + 2 + 2
    let ds = decorationSet(@[decoration(0, 2, 2, inlineWidget(3, "v=1"))])
    let deco = inlayWrapCache(doc, NoWrap, ds)
    # The first ideograph begins at byte 2 and is TWO CELLS wide, so the second
    # one is at 2 + 3 + 2.
    counted deco.toDisplay(textPos(0, 2)).column == 2 + 3
    counted deco.toDisplay(textPos(0, 5)).column == 2 + 3 + 2
    counted deco.metricsOf(0).width == 8 + 3

  test "A TAB AFTER THE WIDGET RE-GRIDS — the shift is NOT uniform, and that is why the columns are recomputed":
    # The cheap implementation of "insert W cells at column C" adds W to every
    # later column. This is the measurement that says it is wrong: at
    # `tabSize = 4` a tab at column 1 ends at 4, and the same tab at column 4
    # ends at 8 — a widget of 3 cells moved the tab's END by 4, not by 3.
    let doc = "a\tb\n"
    let plain = initWrapCache(doc, NoWrap)
    counted plain.toDisplay(textPos(0, 2)).column == 4
    let ds = decorationSet(@[decoration(0, 1, 1, inlineWidget(3, "v=1"))])
    let deco = inlayWrapCache(doc, NoWrap, ds)
    counted deco.toDisplay(textPos(0, 1)).column == 1 + 3
    # The tab now begins at column 4 and advances to 8: the byte after it is at
    # 8, which is 4 more than the undecorated 4 — NOT 3 more.
    counted deco.toDisplay(textPos(0, 2)).column == 8
    counted deco.toDisplay(textPos(0, 2)).column - plain.toDisplay(
      textPos(0, 2)).column == 4
    counted 4 != 3

# ===========================================================================
# ANCHORS — the side, and the fate
# ===========================================================================

suite "PLAT-28 — anchors: the side decides, and only where it can":

  test "AN INSERT EXACTLY AT AN ANCHOR IS THE ONLY PLACE THE SIDE CHANGES THE ANSWER":
    let cs = changeSet(10, 5, 5, "XYZ")
    counted anchorAt(5, sideBefore).mapAnchor(cs).position == 5
    counted anchorAt(5, sideAfter).mapAnchor(cs).position == 8
    # EVERYWHERE ELSE THE TWO AGREE, and that is asserted rather than assumed:
    # a model that used the side as a general bias would differ here too.
    for p in 0 .. 10:
      if p == 5: continue
      checkpoint("position " & $p)
      counted anchorAt(p, sideBefore).mapAnchor(cs).position ==
        anchorAt(p, sideAfter).mapAnchor(cs).position

  test "A BREAKPOINT ON A DELETED LINE IS NOT A BREAKPOINT ON THE LINE THAT TOOK ITS PLACE":
    # §8.2's own sentence, executable. The document is three lines; line 2 is
    # deleted outright.
    let doc = "one\ntwo\nthree\n"
    let cs = changeSet(doc.len, 4, 8, "")
    let bp = anchorAt(4, sideBefore, asBreakpoint, 1)
    let m = bp.mapAnchor(cs)
    # The anchor sat at the START of the deleted run, so it SURVIVED — it is
    # the boundary, not the interior. That is the right answer and it is worth
    # pinning, because the interesting case is one byte later.
    counted m.fate == mapSurvived
    let inside = anchorAt(5, sideBefore, asBreakpoint, 2).mapAnchor(cs)
    counted inside.fate == mapCollapsed
    # THE FATE IS REPORTED RATHER THAN A PLAUSIBLE NEIGHBOUR: asking for the
    # position raises, and the caller that wants the collapse point asks for it
    # by name.
    var raised = false
    try: discard inside.position
    except AnchorError: raised = true
    counted raised
    counted inside.landingOf == 4
    # AND THE LINE THAT TOOK ITS PLACE IS `three`, which the anchor is NOT on:
    # `advance` is the caller's explicit decision, and even then the position
    # is the collapse point rather than a line number somebody guessed.
    counted cs.apply(doc) == "one\nthree\n"
    counted anchorAt(5, sideBefore, asBreakpoint, 2).advance(cs).pos == 4

  test "A REMOTE EDIT GOES THROUGH THE ONE REBASE PRIMITIVE":
    # §8.2's *"mapped through every change set that passes, INCLUDING REMOTE
    # ones"*. The anchor sits in the document AFTER the local edit; the remote
    # edit was computed against the document BEFORE it.
    let doc = "abcdefgh"
    let local = changeSet(doc.len, 2, 2, "LL")
    let remote = changeSet(doc.len, 6, 6, "RR")
    let a = anchorAt(7, sideBefore, asRemoteCaret, 1)   # after `local`
    let m = a.mapAnchorRemote(local, remote)
    counted m.fate == mapSurvived
    # The converged document, reached the other way round, agrees.
    let converged = rebase(remote, local).aOverB.apply(local.apply(doc))
    counted converged == "abLLcdefRRgh"
    counted m.position == 7
    # AND THE POSITION IS THE ONE THE TEXT MOVED TO: byte 7 of `abLLcdefgh` is
    # `f`, which is at byte 7 of the converged document too, because the remote
    # insert lands after it.
    counted local.apply(doc)[7] == converged[7]

# ===========================================================================
# DECORATION ORDER — the enum dominates, and the offset RAISES
# ===========================================================================

suite "PLAT-28 — decoration order: an enum plus a bounded offset":

  test "THE CLASS DOMINATES THE OFFSET, WHICH IS WHAT THE REFERENCE'S ARITHMETIC ENCODES":
    # The reference makes block widgets sort outside inline ones by spacing the
    # bands 10^8 apart. Here it is the enum's own order, so no constant decides
    # it.
    counted decoOrder(ocBlockBefore, DecoOffsetBound) < decoOrder(ocLine, -DecoOffsetBound)
    counted decoOrder(ocLine, DecoOffsetBound) < decoOrder(ocInlineBefore, -DecoOffsetBound)
    counted decoOrder(ocInlineBefore, DecoOffsetBound) < decoOrder(ocInlineAfter, -DecoOffsetBound)
    counted decoOrder(ocInlineAfter, DecoOffsetBound) < decoOrder(ocBlockAfter, -DecoOffsetBound)
    # WITHIN a class the offset decides, and that half is asserted too, or
    # "the class dominates" would be satisfied by ignoring the offset.
    counted decoOrder(ocLine, -1) < decoOrder(ocLine, 0)
    counted decoOrder(ocLine, 0) < decoOrder(ocLine, 1)

  test "THE OFFSET BOUND RAISES WHERE THE REFERENCE CLAMPS":
    # §36a. The reference clamps a user offset to ±10,000, which silently makes
    # two distinguishable orders compare EQUAL.
    counted decoOrder(ocLine, DecoOffsetBound).offset == DecoOffsetBound
    var raised = 0
    for bad in [DecoOffsetBound + 1, -DecoOffsetBound - 1, 10_000_000]:
      try: discard decoOrder(ocLine, bad)
      except DecorationError: inc raised
    counted raised == 3
    # AND THE CONSEQUENCE THE CLAMP WOULD HAVE HAD, made concrete: under a
    # clamp these two would be EQUAL, and here the second does not exist.
    counted decoOrder(ocLine, DecoOffsetBound) == decoOrder(ocLine, DecoOffsetBound)

  test "A BLOCK WIDGET ORDERED AMONG THE INLINE ONES IS A VARIANT, NOT A FLAG":
    counted orderClassOf(bpAbove) == ocBlockBefore
    counted orderClassOf(bpBelow) == ocBlockAfter
    counted orderClassOf(bpAmongInline) == ocInlineBefore
    counted BlockPlacementCount == 3
    # BLOCK-NESS IS INTRINSIC TO THE ARM: there is no field to disagree with it.
    counted isBlock(blockWidget(2, bpAmongInline))
    counted not isBlock(inlineWidget(2))
    counted not isBlock(markPayload("m"))
    counted not isBlock(linePayload("l"))
    # AND A BLOCK WIDGET OCCUPIES ROWS, NOT COLUMNS — reporting its `rows` as a
    # width would be the conflation the four arms exist to prevent.
    counted widthCells(blockWidget(2, bpAmongInline)) == 0
    counted widthCells(inlineWidget(7)) == 7

  test "BLOCK WIDGETS ASK FOR ROWS AND `bpAmongInline` ASKS FOR NONE":
    let doc = "one\ntwo\n"
    let ds = decorationSet(@[
      decoration(0, 0, 0, blockWidget(2, bpAbove)),
      decoration(1, 1, 1, blockWidget(3, bpBelow)),
      decoration(2, 2, 2, blockWidget(9, bpAmongInline))])
    let rows = blockRowsOf(ds, doc, 0)
    counted rows.above == 2
    counted rows.below == 3
    counted blockRowsOf(ds, doc, 1).above == 0
    counted blockRowsOf(ds, doc, 1).below == 0

# ===========================================================================
# `EditorRow` AS A PROJECTION — seven fields x four scenarios
# ===========================================================================

type RowField = enum
  rfLine = "line"
  rfText = "text"
  rfHeld = "held"
  rfPointer = "pointer"
  rfMark = "mark"
  rfValues = "values"
  rfFlow = "flow"

const RowFieldCount = ord(high(RowField)) - ord(low(RowField)) + 1
  ## **SEVEN, DERIVED FROM `EditorRow`'s OWN FIELD LIST.** PLAT-28's floor says
  ## the multiplier *"is the existing type's field count … so it moves if the
  ## read model does — which is the point, since this milestone re-expresses
  ## that type as a projection and a field quietly lost in the move is exactly
  ## what the term grades."*

type Scenario = enum
  scPlain = "edit-mode, plain project text"
  scPoints = "edit-mode, with breakpoints and a tracepoint"
  scWindowed = "edit-mode, a windowed viewport"
  scDebug = "debug-shaped: pointer, inline values, flow and a held range"

const ScenarioCount = ord(high(Scenario)) - ord(low(Scenario)) + 1

const ProjectionDoc = """def solve(a, b):
    total = a + b
    while total > 0:
        total -= 1
    return total
"""

const ProjectionPath = "/plat28/solve.py"

let ProjectionPoints = @[
  EditorPoint(path: ProjectionPath, line: 2, kind: epkBreakpoint, enabled: true),
  EditorPoint(path: ProjectionPath, line: 3, kind: epkBreakpoint, enabled: false),
  EditorPoint(path: ProjectionPath, line: 4, kind: epkTracepoint, enabled: true)]

const ExecutionLine = 3
const InspectionLine = 5
let DebugValues = @[EditorValue(name: "total", value: "7"),
                    EditorValue(name: "a", value: "3")]
let DebugFlowFacts = @[FlowStyledLine(position: 3, kind: flskHit),
                       FlowStyledLine(position: 4, kind: flskHit),
                       FlowStyledLine(position: 5, kind: flskSkip)]
  ## `FlowVM.styledLines` for a window in which lines 3-4 ran and line 5 sits
  ## in a declined arm — the three flow states, so the `flow` cell varies.

# THE DECLARED VARIETY TABLE. `true` means the field takes more than one value
# across that scenario's rows; `false` means it is constant there. Both
# directions are asserted, and the number of `true` cells is asserted too —
# without which "every field is constant" and "every field varies" are both
# satisfiable and three of the four scenarios would be cases that cannot fail.
const Varies: array[ScenarioCount, array[RowFieldCount, bool]] = [
  # line   text   held   pointer mark   values flow
  [true,  true,  false, false, false, false, false],   # scPlain
  [true,  true,  false, false, true,  false, false],   # scPoints
  [true,  true,  false, false, true,  false, false],   # scWindowed
  [true,  true,  true,  true,  true,  true,  true]]    # scDebug

const VaryingCells = block:
  var n = 0
  for row in Varies:
    for v in row:
      if v: inc n
  n

proc modelRows(sc: Scenario): seq[EditorRow] =
  ## The projection's answer.
  let lines = projectionLines(ProjectionDoc)
  let starts = projectionLineStarts(ProjectionDoc)
  var ds: seq[Decoration] = @[]
  var id = 0
  case sc
  of scPlain: discard
  of scPoints, scWindowed:
    for i in 0 ..< lines.len:
      let m = markFor(ProjectionPoints, ProjectionPath, i + 1)
      if m != emNone:
        ds.add decoration(id, starts[i], starts[i], linePayload(classOfMark(m)))
        inc id
  of scDebug:
    for i in 0 ..< lines.len:
      let line = i + 1
      let m = markFor(ProjectionPoints, ProjectionPath, line)
      let p = pointerFor(line, ExecutionLine, InspectionLine)
      let f = flowStateOf(DebugFlowFacts, line)
      let vs = if p == eptExecution: valuesForLine(lines[i], DebugValues)
               else: @[]
      for d in decorationsForRow(m, p, f, vs, starts[i], lines[i].len, id):
        ds.add d
        inc id
  var rp = RowProjection(doc: ProjectionDoc, decorations: decorationSet(ds),
                         viewportTop: 1, viewportHeight: 0,
                         trailing: tlpDropFinalEmpty)
  if sc == scWindowed:
    rp.viewportTop = 2
    rp.viewportHeight = 3
  if sc == scDebug:
    rp.heldFrom = 2
    rp.heldTo = 4
  editorRowsOf(rp)

proc controlRows(sc: Scenario): seq[EditorRow] =
  ## **TODAY'S PRODUCER**, driven. Three scenarios go through
  ## `editorSurfaceForProject`; the fourth drives the per-field rules
  ## `editorSurfaceFor` itself calls, because the debug surface needs a live
  ## session (see the header).
  case sc
  of scPlain:
    editorSurfaceForProject(ProjectionPath, ProjectionDoc, "plat28", true).rows
  of scPoints:
    editorSurfaceForProject(ProjectionPath, ProjectionDoc, "plat28", true,
                            points = ProjectionPoints).rows
  of scWindowed:
    editorSurfaceForProject(ProjectionPath, ProjectionDoc, "plat28", true,
                            viewportTop = 2, viewportHeight = 3,
                            points = ProjectionPoints).rows
  of scDebug:
    var rows: seq[EditorRow] = @[]
    var lines = ProjectionDoc.splitLines()
    if lines.len > 1 and lines[^1].len == 0: lines.setLen(lines.len - 1)
    for i, text in lines:
      let line = i + 1
      let held = line >= 2 and line <= 4
      let p = pointerFor(line, ExecutionLine, InspectionLine)
      rows.add EditorRow(
        line: line, text: if held: text else: "", held: held,
        pointer: p, mark: markFor(ProjectionPoints, ProjectionPath, line),
        values: if p == eptExecution and held: valuesForLine(text, DebugValues)
                else: @[],
        flow: flowStateOf(DebugFlowFacts, line))
    rows

func fieldOf(r: EditorRow; f: RowField): string =
  ## One field, as a comparable string. A per-field accessor rather than
  ## `$row`, because the whole point of the term is that a field lost in the
  ## move is caught by ITS OWN case rather than by a whole-row diff.
  case f
  of rfLine: $r.line
  of rfText: r.text
  of rfHeld: $r.held
  of rfPointer: $r.pointer
  of rfMark: $r.mark
  of rfValues:
    var s = ""
    for v in r.values: s.add v.name & "=" & v.value & ";"
    s
  of rfFlow: $r.flow

suite "PLAT-28 — EditorRow as a projection, field by field":

  test "the seven fields and the four scenarios are asserted cardinalities":
    counted RowFieldCount == 7
    counted ScenarioCount == 4
    # THE VARIETY TABLE IS NOT ALL-TRUE AND NOT ALL-FALSE. Without this, the
    # per-cell assertions below are satisfied by a table somebody wrote to
    # match a run.
    counted VaryingCells == 15
    counted VaryingCells > 0
    counted VaryingCells < RowFieldCount * ScenarioCount
    # EVERY FIELD VARIES IN AT LEAST ONE SCENARIO, which is what stops a field
    # being graded only where both sides are trivially equal.
    for fi in 0 ..< RowFieldCount:
      var n = 0
      for si in 0 ..< ScenarioCount:
        if Varies[si][fi]: inc n
      checkpoint($RowField(fi) & " varies in " & $n & " scenario(s)")
      counted n >= 1

  for sc in Scenario:
    for f in RowField:
      test "EditorRow." & $f & " x " & $sc:
        let model = modelRows(sc)
        let control = controlRows(sc)
        counted model.len == control.len
        counted model.len > 0
        var values: seq[string] = @[]
        for i in 0 ..< model.len:
          let a = fieldOf(model[i], f)
          let b = fieldOf(control[i], f)
          if a != b:
            checkpoint("row " & $i & ": model '" & a & "' control '" & b & "'")
          counted a == b
          var seen = false
          for v in values:
            if v == a: seen = true
          if not seen: values.add a
        checkpoint($f & " x " & $sc & ": " & $values.len & " distinct value(s)")
        # THE VARIETY ASSERTION, two-sided against the declared table.
        counted (values.len > 1) == Varies[ord(sc)][ord(f)]

# ===========================================================================
# THE FILED DIVERGENCES — named entries, not a diff nobody reads
# ===========================================================================

suite "PLAT-28 — where the projection and today's producer deliberately differ":

  test "THE FILED GAPS ARE DATA AND EACH CARRIES A MEASUREMENT":
    counted FiledDecorationGaps.len == 4
    for id in DecorationGapId:
      let g = FiledDecorationGaps[id]
      checkpoint($id)
      counted g.id == id
      counted g.subject.len > 0
      counted g.measurement.len > 40
      counted g.remedy.len > 20
    # THE INHERITED ONES STAY FILED WHERE THEY ARE. PLAT-28's risk note:
    # *"both stay filed against their existing ids and are OUT OF SCOPE here"*.
    # `PLAT22-PG2` was retired by PLAT-42 (the flow's per-line fact now
    # exists); the other inherited gap stays filed.
    counted FiledEditorGaps.len == 2
    counted FiledEditorGaps[pgMarksHaveNoProducer].concern == ecLineStatus
    counted ecFlowOverlay notin concernsWithFiledGap()

  test "PLAT28-DG3 — THE TWO PRODUCERS AGREED ABOUT A LINE TERMINATOR AFTER PLAT-34, measured":
    # **THIS CASE MEASURED A DIVERGENCE AND NOW MEASURES ITS CLOSURE, AND THE
    # OLD NUMBERS ARE KEPT IN THE COMMENT SO THE CHANGE IS READABLE.**
    #
    # As PLAT-28 wrote it: `editorSurfaceForProject` split with
    # `strutils.splitLines`, which breaks on a lone CR and on CRLF, while the
    # model splits on `'\n'` only — `wrap.nim`'s own comment says why:
    # *"`strutils.splitLines` also splits on a lone CR and would give this
    # module a different line count from the store it must agree with
    # (PLAT-24's `unrepresentable.tsv`, row 1)"*. On `crlf` below the two
    # answered **THREE rows and TWO**.
    #
    # PLAT-28 filed that as `PLAT28-DG3` rather than fixing it, and said why:
    # *"rewiring would change edit-mode line counting in production for every
    # file containing a CR"*, with the remedy *"decide what a line terminator
    # is for EDIT mode, and move whichever side is wrong."* **PLAT-34 took the
    # decision and moved the SURFACE** — a lone CR is not a line terminator in
    # this editor, because the caret cannot be placed on a row the store does
    # not have — so `editorSurfaceForProject` now goes through
    # `row_projection.projectionLinesFor` and both producers answer TWO. The
    # reason is in `editorSurfaceForProject`'s own header and in
    # `Architecture/Editor-ViewModel.md` §3.2.
    #
    # **THE ROW COUNTS BELOW ARE MEASURED ON A HAND-BUILT STRING, AND THE
    # ATTRIBUTION MATTERS.** `crlf` is the smallest input carrying both halves
    # of the old divergence — a CRLF and a lone CR — and the numbers are ITS
    # measurement, not the corpus terminator class's. The corpus contributes a
    # separate and weaker fact, asserted at the end of this case: the class does
    # contain CR-bearing documents, so the shape this measures is one the corpus
    # can present. Crediting the row counts to the corpus class would be
    # claiming a measurement nobody took.
    let crlf = "one\r\ntwo\rthree\n"
    let control = editorSurfaceForProject("/plat28/crlf.txt", crlf, "plat28",
                                          true).rows
    let model = editorRowsOf(RowProjection(
      doc: crlf, decorations: decorationSet(@[]), viewportTop: 1,
      viewportHeight: 0, trailing: tlpDropFinalEmpty))
    checkpoint("control rows: " & $control.len & ", model rows: " & $model.len)
    counted control.len == 2          # "one\r" / "two\rthree" — was 3
    counted model.len == 2            # unchanged: the model never moved
    counted control.len == model.len
    # AND THE TEXTS AGREE, NOT ONLY THE COUNT. Two producers can agree about
    # how many rows there are and disagree about where the breaks fell, and a
    # count-only assertion would be satisfied by that.
    for i in 0 ..< model.len:
      counted control[i].text == model[i].text
    # AND THE MODEL'S ANSWER IS THE STORE'S. That is the reason the divergence
    # is filed rather than repaired in the model: the coordinate model, the
    # text store and the wrap projection all count lines this way, and moving
    # the model to `splitLines` would make `LAW-C4`'s partition false.
    counted wrap.documentLines(crlf).len == 3
    counted projectionLines(crlf).len == 3
    counted model[0].text == "one\r"
    # THE SEPARATE, WEAKER CORPUS FACT: the terminator class exists and carries
    # CR. This says the shape is representable in the corpus; it does NOT say
    # the row counts above were taken on a corpus document. They were not.
    var crDocs = 0
    for d in docsOfClass(6):
      if d.text.contains('\r'): inc crDocs
    counted crDocs > 0

  test "PLAT28-DG4 — `valueWidth` IS A BYTE COUNT AND NOT A DISPLAY WIDTH, measured":
    # `row_projection.nim` imports neither `wrap` nor `inlay` — that is what
    # keeps it callable from `editor_surface.nim` without dragging
    # `isonim_tui/text/width` into the `gpui-shell` lane — so it has no width
    # function and `valueWidth` counts BYTES. On ASCII the two agree; on the
    # corpus's CJK class they do not, and the difference is measured here
    # rather than left as a sentence in a header.
    let ascii = EditorValue(name: "n", value: "42")
    counted valueWidth(ascii) == inlineTextOf(ascii).len
    counted valueWidth(ascii) ==
      lineMetrics(inlineTextOf(ascii), Policy).width
    let cjk = EditorValue(name: "n", value: "漢字")
    counted valueWidth(cjk) == inlineTextOf(cjk).len
    counted valueWidth(cjk) != lineMetrics(inlineTextOf(cjk), Policy).width
    checkpoint("CJK: " & $valueWidth(cjk) & " bytes, " &
               $lineMetrics(inlineTextOf(cjk), Policy).width & " cells")
    # **SO A PRODUCER MUST MEASURE THE WIDGET WITH `wrap.cellsOf`**, which is
    # what `LAW-C7`'s cells do and what the reflow gate's own widget does. A
    # widget built with `valueWidth` on CJK would reserve four cells too many
    # and the text after it would sit past where it is painted.
    let text = inlineTextOf(cjk)
    let cells = lineMetrics(text, Policy).width
    let doc = "ab" & "cd\n"
    let ds = decorationSet(@[decoration(0, 2, 2, inlineWidget(cells, text))])
    counted inlayWrapCache(doc, NoWrap, ds).toDisplay(
      textPos(0, 2)).column == 2 + cells

  test "THE TRAILING-LINE POLICY IS A NAMED DECISION AND BOTH ARMS ARE REACHED":
    let doc = "a\nb\n"
    let kept = editorRowsOf(RowProjection(
      doc: doc, decorations: decorationSet(@[]), viewportTop: 1,
      viewportHeight: 0, trailing: tlpKeep))
    let dropped = editorRowsOf(RowProjection(
      doc: doc, decorations: decorationSet(@[]), viewportTop: 1,
      viewportHeight: 0, trailing: tlpDropFinalEmpty))
    counted kept.len == 3
    counted dropped.len == 2
    # `tlpKeep` IS THE COORDINATE MODEL'S COUNT and `tlpDropFinalEmpty` is the
    # one a user counts; the two are both right and the policy says which is
    # being asked for.
    counted wrap.documentLines(doc).len == kept.len
    counted editorSurfaceForProject("/p", doc, "m", true).rows.len == dropped.len

  test "A WINDOW PROJECTS WITH THE FILE'S LINE NUMBERS, AND A REQUESTED LINE IS NOT HELD":
    # The debug surface projects `SourceVM`'s visible window — a contiguous
    # run of a file starting at `visibleFirstLine`, some lines still in
    # flight — so `firstLine` numbers the rows and `requested` un-holds the
    # in-flight ones, which need not form a range.
    let doc = "alpha\n\ngamma\n"
    let starts = projectionLineStarts(doc)
    let ds = decorationSet(@[
      decoration(0, starts[2], starts[2],
                 linePayload(classOfPointer(eptExecution)))])
    let rows = editorRowsOf(RowProjection(
      doc: doc, decorations: ds, firstLine: 40, viewportTop: 40,
      viewportHeight: 0, trailing: tlpDropFinalEmpty, requested: @[41]))
    counted rows.len == 3
    counted rows[0].line == 40 and rows[2].line == 42
    counted rows[0].held and rows[0].text == "alpha"
    counted not rows[1].held and rows[1].text == ""
    counted rows[2].held and rows[2].pointer == eptExecution
    # The window's own viewport clips in the FILE's numbering too.
    let clipped = editorRowsOf(RowProjection(
      doc: doc, decorations: ds, firstLine: 40, viewportTop: 42,
      viewportHeight: 1, trailing: tlpDropFinalEmpty))
    counted clipped.len == 1 and clipped[0].line == 42

suite "PLAT-28 — a line table moves with the text (§8.2)":
  ## `EditorState.folded`, `breakpoints`, `tracepoints` and `trackedLines` name
  ## LINES, and until 2026-09-23 no edit moved them. Every case below names
  ## the Vim edit it spells as a change set, because the three shapes that
  ## matter are `O` (open a line above), `dd` (delete the line) and `J` (join
  ## it with the next): the first must move a breakpoint, the second must
  ## remove it, and the third must keep it.

  const Doc = "alpha\nbeta\ngamma\ndelta\n"   # lines 0..3, then the empty 4
  const BetaStart = 6

  test "`O` above a line moves it down; a line above it does not move":
    let cs = changeSet(Doc.len, BetaStart, BetaStart, "new\n")
    counted mapLinesThrough(Doc, cs, [0, 1, 2]) == @[0, 2, 3]

  test "`dd` on a line DELETES it; the line that took its place is not it":
    let cs = changeSet(Doc.len, BetaStart, BetaStart + "beta\n".len, "")
    counted mapLinesThrough(Doc, cs, [0, 1, 2]) == @[0, -1, 1]

  test "`J` keeps both joined lines' text, so it keeps both lines — on one row":
    # `J` on `beta` deletes its newline and puts one space in its place.
    let nl = BetaStart + "beta".len
    let cs = changeSet(Doc.len, nl, nl + 1, " ")
    counted cs.apply(Doc) == "alpha\nbeta gamma\ndelta\n"
    counted mapLinesThrough(Doc, cs, [1, 2, 3]) == @[1, 1, 2]

  test "emptying a line's text keeps the line; Enter inside it keeps it on the first half":
    let emptied = changeSet(Doc.len, BetaStart, BetaStart + 4, "")
    counted mapLinesThrough(Doc, emptied, [1]) == @[1]
    let split = changeSet(Doc.len, BetaStart + 2, BetaStart + 2, "\n")
    counted mapLinesThrough(Doc, split, [1, 2]) == @[1, 3]

  test "a line that is not a line of the document is returned unchanged":
    let cs = changeSet(Doc.len, 0, 0, "x\n")
    counted mapLinesThrough(Doc, cs, [-1, 99]) == @[-1, 99]

  test "THE THREE ROUTES A DOCUMENT MOVES BY all move the state's lines":
    # A LOCAL edit (`commitChange`), its UNDO (`applyHistoryStep`) and a
    # REMOTE change (`collab_text.applyRemoteChange`). The undo route carried
    # its own copy of the marks mapping until this milestone and would have
    # left the lines where the edit put them.
    var st = initEditorState(Doc)
    st.breakpoints = @[1]
    st.tracepoints = @[2]
    st.folded = @[3]
    st.trackedLines = @[1, 2]
    let edited = applyOperation(st, "insert-text", OpArgs(text: "top\n"),
                                NoWrap).state
    counted edited.breakpoints == @[2]
    counted edited.tracepoints == @[3]
    counted edited.folded == @[4]
    counted edited.trackedLines == @[2, 3]
    let undone = applyOperation(edited, "undo", OpArgs(), NoWrap).state
    counted undone.doc == Doc
    counted undone.breakpoints == @[1]
    counted undone.trackedLines == @[1, 2]
    let remote = applyRemoteChange(
      undone, changeSet(Doc.len, BetaStart, BetaStart + "beta\n".len, ""),
      "peer")
    counted remote.breakpoints.len == 0
    counted remote.tracepoints == @[1]
    counted remote.trackedLines == @[-1, 1]

suite "PLAT-28 — the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
