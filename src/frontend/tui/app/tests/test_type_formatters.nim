## test_type_formatters.nim — CTUI-7, Tier 1, PURE.
##
## ## What this suite is for, and why it exists although CTUI-7 does not name it
##
## The three suites CTUI-7 names all drive a real trace, and between them they
## exercise the formatter arms CTUI-1's corpus produces: integers, strings,
## booleans, `nil`, sequences, tuples, opaque reprs and Noir's hex-literal field
## elements. **Four arms have no fixture at all** — a byte buffer, a pointer with
## a dereferenced target, a labelled struct and an enum — because no recorder in
## this workspace emits one. They are exercised here, on constructed values,
## exactly as CTUI-6 exercised the `lib` badge it had no trace for.
##
## ## PLAT-2 MOVED THE SUBJECT, AND THIS SUITE FOLLOWED IT
##
## `type_formatters` no longer classifies, truncates, dumps bytes or produces
## hexadecimal companions; `common/value_presentation/` does, for all seven
## surfaces, and `src/common/value_presentation_test.nim` is where those rules
## are asserted. What is asserted HERE is what is still this front-end's:
##
##   * that the terminal's own measure (`terminalMeasure`) is what the presenter
##     truncates by, so a row's value column is right in CELLS and not in runes;
##   * that a row asks the presenter for the width it actually has, rather than
##     receiving an unbounded string and clipping it;
##   * that the class -> colour table covers the vocabulary.
##
## The four fixture-less arms are still exercised here, through the ROW, which
## is the level at which this front-end owns the answer.
##
## Three more things live here for the same reason: they are PURE, and a real
## trace could not make them fail more precisely.
##
##   * The `ValueTimeline`'s ANCHOR RULE and its EVICTION BOUND. The bound is
##     unreachable from a fixture — it takes more stops than a suite should
##     drive — and it is the thing that decides whether a long session grows
##     without limit.
##   * The `[MOD]` field's COLUMN. The Tier-2 case reads a cell there; if the
##     two arithmetics drifted, that case would read the wrong cell and pass.
##   * The shell painting this pane into the `state` rectangle.
##
## ## It stays under `app/tests/`, and that is the point
##
## `tests/test_tui_facade_boundary.nim` walks every `.nim` under `app/`,
## including this file, so a suite placed here cannot import `host/`,
## `headless_session`, `std/posix` or `std/osproc` without reddening that guard.
## This one needs none of them, which is exactly the property that makes it
## belong here rather than one directory up — the convention CTUI-5 named and
## CTUI-6 followed with `test_call_stack_keys.nim`.
##
## ## No mocks
##
## Nothing here constructs a ViewModel or a backend. The values are literals and
## the subject is a pure function of them.
##
## ## Templates, not procs, for anything that calls `check`

import std/[strutils, tables, unicode, unittest]

import isonim_tui

import headless_app/layout_model

import ../../../../common/value_presentation
import ../formatters/type_formatters
import ../views/shell
import ../views/tree_node
import ../views/variables

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 146

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  RowWidth = 60

proc sampleChildren(nodes: seq[VarNode]): NodeChildren =
  ## A seam over a constant, for the pure cases. It answers ONE node — the
  ## scope root — and a window of it, which is all the pure cases need; the
  ## suites that drive a real trace exercise the deep case.
  let held = nodes
  result = proc(path: string; offset, limit: int):
      tuple[nodes: seq[VarNode]; total: int] =
    result = (nodes: @[], total: 0)
    if path != scopePath(skLocals):
      return
    result.total = held.len
    for i in max(0, offset) ..< min(held.len, offset + limit):
      result.nodes.add held[i]

proc rowFor(spec: TreeRowSpec): string =
  treeRowText(spec)

proc cellAt(row: string; index: int): string =
  ## One CELL of a rendered row, by column. By cell rather than by byte, because
  ## the expander glyphs are multi-byte and the marker columns are the whole
  ## point of the layout.
  var at = 0
  for r in row.runes:
    let w = max(1, cellWidthOf($r))
    if at == index:
      return $r
    at += w
  ""

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

proc pv(kind: PValueKind; text, typeName, sourceKind: string): PValue =
  PValue(kind: kind, text: text, typeName: typeName, sourceKind: sourceKind)

proc rowSpec(pval: PValue; focused = false; cells = 40): TreeRowSpec =
  ## One variable row over a value, at a stated width. The width is the point:
  ## `formattedValue` takes it and returns what fits.
  TreeRowSpec(kind: trkVariable, name: "v",
              typeName: (if pval.isNil: "" else: pval.typeName),
              value: present(pval, tuiValueBudget()).root.text,
              presented: pval, depth: 1, focused: focused, width: cells)

template checkClass(pval: PValue; want: PresentationClass) =
  let got = valueClassOf(rowSpec(pval))
  checkpoint("class = " & $got & ", wanted " & $want)
  ck got == want

# ---------------------------------------------------------------------------

suite "CTUI-7 after PLAT-2: what is still this front-end's":

  test "a row's class comes from the presenter, including the arms no fixture produces":
    # BEFORE PLAT-2 this was `classifyValue(typeName, value)` — an inference
    # from the SHAPE of an already-rendered string, which was all this pane had.
    # It is now the kind the engine reported, so a value whose rendering carries
    # no recognisable bracket is classified correctly instead of silently
    # landing on `vcUnknown` and being painted in the default colour.
    checkClass(pv(pvkInt, "600", "Int", "Int"), pcInteger)
    checkClass(pv(pvkFloat, "0.5", "Float", "Float"), pcFloat)
    checkClass(pv(pvkString, "shield online", "String", "String"), pcString)
    checkClass(pv(pvkBool, "true", "Bool", "Bool"), pcBoolean)
    checkClass(pv(pvkNil, "", "NoneType", "None"), pcNone)
    checkClass(pv(pvkChar, "x", "Char", "Char"), pcChar)
    checkClass(pv(pvkRaw, "<function main at 0x7f00>", "Object", "Raw"), pcOpaque)
    checkClass(pv(pvkString,
      "0x0000000000000000000000000000000000000000000000000000000000002710",
      "Field", "String"), pcHexLiteral)
    checkClass(pv(pvkError, "unreadable", "Error", "Error"), pcError)
    checkClass(pv(pvkPointer, "0x7ffd0000", "Pointer", "Pointer"), pcPointer)
    checkClass(pv(pvkEnum, "1", "Colour", "Enum"), pcEnum)
    # A record and a tuple are DIFFERENT classes now. They used to be told apart
    # by whether the rendering started with `{` or `(`, which is why
    # `headless_session`'s decoder deliberately wrote a struct `{…}` where the
    # desktop wrote `Type(…)` — a wire-level divergence introduced to feed a
    # string-shape classifier. Both are gone.
    checkClass(PValue(kind: pvkRecord, typeName: "Point", sourceKind: "Instance",
                      members: @[member("x", pv(pvkInt, "10", "Int", "Int"))]),
               pcRecord)
    checkClass(PValue(kind: pvkTuple, typeName: "Tuple", sourceKind: "Tuple",
                      members: @[member("", pv(pvkInt, "10", "Int", "Int"))]),
               pcTuple)
    # A row with no value at all — a scope header — is still a row.
    checkClass(nil, pcNone)

  test "the class -> colour table covers the vocabulary":
    # Every class must have a style, or a value would be painted in whatever the
    # previous span left behind. Asserted by ENUMERATION, so a class added by
    # PLAT-3 or PLAT-12 cannot arrive unstyled.
    var styled = 0
    for class in PresentationClass:
      let style = valueStyle(class)
      ck style.fg.len > 0
      inc styled
    ck styled == 20
    ck valueStyle(pcInteger) == NumberStyle
    ck valueStyle(pcHexLiteral) == NumberStyle
    ck valueStyle(pcString) == StringStyle
    ck valueStyle(pcError) == ErrorStyle
    ck valueStyle(pcMedia) == MediaStyle

  test "the terminal's measure is in CELLS, and it is what the presenter clips by":
    # THE MEASURE IS THIS FRONT-END'S CONTRIBUTION TO THE PIPELINE. A truncation
    # that counted runes would overflow the value column by one cell per wide
    # glyph, and a pane whose value column overflows corrupts every column after
    # it.
    ck terminalMeasure("abc") == 3
    ck terminalMeasure("世界") == 4
    ck terminalMeasure("") == 0
    ck terminalMeasure("世") == 2
    # …and the row's own value, asked for at five cells, comes back at five.
    let wide = pv(pvkString, "世界世界", "String", "String")
    let shown = formattedValue(rowSpec(wide, cells = 5), 5)
    checkpoint("clipped: '" & shown & "' = " & $terminalMeasure(shown) & " cells")
    ck terminalMeasure(shown) <= 5
    ck shown.endsWith("…")
    # The same value at a width that fits is NOT clipped.
    let full = formattedValue(rowSpec(wide, cells = 20), 20)
    ck full == "\"世界世界\""
    ck not full.endsWith("…")

  test "a row asks for the width it has, rather than clipping what it was given":
    # THE DELIVERABLE, at the row. `formattedValue(spec, cells)` returns what
    # fits; there is no `truncate(formattedValue(spec))` anywhere, and
    # `ci/test/value-presentation-boundary.sh` fails if one appears.
    var members: seq[PMember] = @[]
    for k in 0 ..< 600:
      members.add member("", pv(pvkInt, $(1000 + k), "Int", "Int"))
    let wideValue = PValue(kind: pvkSequence, typeName: "list",
                           sourceKind: "Seq", members: members)
    for cells in [4, 8, 20, 40]:
      let text = formattedValue(rowSpec(wideValue, cells = cells), cells)
      checkpoint("at " & $cells & " cells: '" & text & "'")
      ck terminalMeasure(text) <= cells

  test "the focused row carries the second numeric base, and only when focused":
    let n = pv(pvkInt, "306", "Int", "Int")
    ck formattedValue(rowSpec(n, focused = false), 40) == "306"
    ck formattedValue(rowSpec(n, focused = true), 40) == "306 (0x132)"
    let field = pv(pvkString,
      "0x0000000000000000000000000000000000000000000000000000000000002710",
      "Field", "String")
    ck formattedValue(rowSpec(field, focused = true), 40) == "0x2710 (10000)"
    # A class with no second rendering is unchanged by focus.
    let s2 = pv(pvkString, "x", "String", "String")
    ck formattedValue(rowSpec(s2, focused = true), 40) ==
       formattedValue(rowSpec(s2, focused = false), 40)

  test "a byte buffer is decided by its members, and the length is always reported":
    var bytes: seq[PMember] = @[]
    for b in [0, 17, 34, 255]:
      bytes.add member("", pv(pvkInt, $b, "Int", "Int"))
    let buffer = PValue(kind: pvkSequence, typeName: "Bytes",
                        sourceKind: "Seq", members: bytes)
    let dump = formattedValue(rowSpec(buffer, cells = 60), 60)
    checkpoint("byte dump: '" & dump & "'")
    ck dump == "00 11 22 ff (4 bytes)"
    ck valueClassOf(rowSpec(buffer)) == pcSequence
    # WHICH PRESENTER ANSWERED, reportably — PLAT-2's fourth deliverable, at
    # the row a user is looking at.
    let attribution = present(buffer, tuiRowBudget(60, false)).attribution
    ck attribution.presenter == "builtin.byte-buffer"
    ck "builtin.sequence" in attribution.candidates
    # One member out of range takes the same value to the other presenter.
    var notBytes = bytes
    notBytes.add member("", pv(pvkInt, "300", "Int", "Int"))
    let notBuffer = PValue(kind: pvkSequence, typeName: "Bytes",
                           sourceKind: "Seq", members: notBytes)
    ck present(notBuffer, tuiRowBudget(60, false)).attribution.presenter ==
       "builtin.sequence"

  test "the string detail this pane offers is still this pane's":
    ck stringDetail("\"hello\"") == "5 chars"
    ck stringDetail("\"世界\"") == "2 chars"

suite "CTUI-7: one row of the tree, and where its fields land":

  test "the marker columns are the same on every kind of row":
    let leaf = TreeRowSpec(kind: trkVariable, name: "counter",
                           typeName: "Int", value: "41",
                           presented: pv(pvkInt, "41", "Int", "Int"),
                           depth: 1, width: RowWidth)
    var expandable = leaf
    expandable.name = "point"
    expandable.expandable = true
    expandable.memberCount = 2
    var opened = expandable
    opened.expanded = true
    var modified = leaf
    modified.modified = true
    var deep = leaf
    deep.depth = 3

    ck cellAt(rowFor(leaf), 0) == LeafGlyph
    ck cellAt(rowFor(expandable), 0) == CollapsedGlyph
    ck cellAt(rowFor(opened), 0) == ExpandedGlyph
    # THE `[MOD]` FIELD IS AT THE SAME COLUMN ON EVERY ROW, blank when the row
    # did not change. The Tier-2 case reads a real terminal cell at exactly this
    # column, so a drift here would move that read rather than the badge.
    ck diffFieldColumn() == 2
    ck nameFieldColumn() == 8
    ck rowFor(modified)[2 .. 6] == ModifiedTag
    ck rowFor(leaf)[2 .. 6] == "     "
    ck diffTagText(modified) == ModifiedTag
    ck diffTagText(leaf).len == ModifiedTagCells
    # THE INDENT MOVES THE NAME, NEVER THE ROW.
    ck cellAt(rowFor(deep), 0) == LeafGlyph
    ck rowFor(deep)[2 .. 6] == "     "
    ck rowFor(deep).find("counter") ==
       rowFor(leaf).find("counter") + 2 * IndentCells
    # Every row is exactly the width it was asked for, whatever its kind.
    var widths: seq[int] = @[]
    for spec in [leaf, expandable, opened, modified, deep]:
      widths.add cellWidthOf(rowFor(spec))
    checkpoint("row widths: " & $widths)
    ck widths == @[RowWidth, RowWidth, RowWidth, RowWidth, RowWidth]
    ck widths.len == 5

  test "the fields share the row, and the value keeps what is left":
    let wide = fieldWidths(RowWidth)
    checkpoint("at " & $RowWidth & ": name " & $wide.name & ", type " &
               $wide.typ & ", value " & $wide.value)
    ck wide.name >= MinimumNameCells
    ck wide.name <= MaximumNameCells
    ck wide.typ <= MaximumTypeCells
    ck wide.value >= MinimumValueCells
    ck wide.name + wide.typ + wide.value + 2 ==
       RowWidth - nameFieldColumn() - tree_node.ReservedTrailingCells
    # A NARROW PANE DROPS THE TYPE, NOT THE VALUE: a name and a value answer
    # "what is it now", and the type is a detail the tree's own shape carries.
    let narrow = fieldWidths(22)
    checkpoint("at 22: name " & $narrow.name & ", type " & $narrow.typ &
               ", value " & $narrow.value)
    ck narrow.typ == 0
    ck narrow.value >= MinimumValueCells
    ck narrow.name >= MinimumNameCells
    # …and a pane too narrow for anything reports zeros rather than negatives.
    let tiny = fieldWidths(4)
    ck tiny.name >= 0
    ck tiny.value >= 0

  test "a `… N more` row names the number":
    ck moreRowText(550) == "… 550 more"
    let spec = TreeRowSpec(kind: trkMore, depth: 2, memberCount: 550,
                           width: RowWidth)
    let text = rowFor(spec)
    checkpoint("more row: '" & text & "'")
    ck text.contains("550")
    ck text.contains("more")
    ck cellWidthOf(text) == RowWidth
    ck cellAt(text, 0) == LeafGlyph

suite "CTUI-7: the diff timeline's anchor rule and its bound":

  test "the anchor is the recording's predecessor, and absent when unseen":
    var timeline = initValueTimeline()
    var a = initTable[string, string]()
    a["x"] = "1"
    a["y"] = "9"
    var b = initTable[string, string]()
    b["x"] = "2"
    b["y"] = "9"
    var c = initTable[string, string]()
    c["x"] = "2"
    c["y"] = "9"
    c["z"] = "0"

    timeline.observe(10, a)
    # WITH NO PREDECESSOR, NOTHING IS MARKED, and the diff says why rather than
    # marking every row — which is the naive answer and the one that lights up
    # the first stop of every session.
    let first = timeline.diffAt(10)
    ck first.currentKnown
    ck not first.anchorKnown
    ck first.modifiedPaths().len == 0
    ck first.changes.len == 0

    timeline.observe(11, b)
    let second = timeline.diffAt(11)
    ck second.anchorKnown
    ck second.anchorTick == 10
    ck second.modifiedPaths() == @["x"]
    ck second.changeFor("x") == vchModified
    ck second.changeFor("y") == vchUnchanged
    ck second.isModified("x")
    ck not second.isModified("y")

    timeline.observe(12, c)
    let third = timeline.diffAt(12)
    ck third.anchorTick == 11
    ck third.modifiedPaths() == @["z"]
    ck third.changeFor("z") == vchAdded
    ck third.isModified("z")

    # THE BACKWARD CASE, which is the whole contract: at tick 11 the anchor is
    # 10 whether the caller arrived from 10 or from 12. So revisiting 11 after
    # 12 says exactly what it said the first time — and NOT that `z` was
    # removed, which is what a diff against "the tick we came from" would say.
    let revisited = timeline.diffAt(11)
    ck revisited.anchorTick == 10
    ck revisited.modifiedPaths() == second.modifiedPaths()
    ck revisited.changeFor("z") == vchUnchanged
    # …and the non-vacuity twin: the two ticks really do differ, so a symmetric
    # diff would have marked `z`.
    ck timeline.snapshotAt(12).values.hasKey("z")
    ck not timeline.snapshotAt(11).values.hasKey("z")
    # A REMOVED binding is reported as removed and NOT badged: it has no row.
    var back = timeline.diffAt(11)
    ck back.changes.len == 1
    ck back.isModified("x")
    # An unobserved tick answers "I was never asked about this" rather than
    # marking nothing quietly.
    let unknown = timeline.diffAt(99)
    ck not unknown.currentKnown
    ck not unknown.anchorKnown
    ck unknown.changes.len == 0
    ck describe(unknown).contains("never observed")

  test "the timeline is bounded, and keeps what is being walked":
    var timeline = initValueTimeline(capacity = 4)
    for tick in 1 .. 10:
      var values = initTable[string, string]()
      values["x"] = $tick
      timeline.observe(uint64(tick), values)
    checkpoint("held ticks: " & $timeline.observedTicks())
    ck timeline.len == 4
    ck timeline.observedTicks() == @[7'u64, 8'u64, 9'u64, 10'u64]
    # The bound is a bound and not a truncation: the newest four are held and
    # the diff still works over them.
    ck timeline.diffAt(10).anchorTick == 9
    ck timeline.diffAt(10).modifiedPaths() == @["x"]
    ck not timeline.hasTick(6)
    # RE-OBSERVING MAKES AN ENTRY THE MOST RECENTLY USED, so a region being
    # walked back and forth stays resident while one visited once is dropped.
    var refreshed = initTable[string, string]()
    refreshed["x"] = "7"
    timeline.observe(7, refreshed)
    var extra = initTable[string, string]()
    extra["x"] = "11"
    timeline.observe(11, extra)
    checkpoint("after refresh: " & $timeline.observedTicks())
    ck timeline.hasTick(7)
    ck not timeline.hasTick(8)
    ck timeline.len == 4
    # …and a capacity below the floor is raised rather than accepted, because a
    # timeline of one can never have an anchor.
    var tiny = initValueTimeline(capacity = 0)
    ck tiny.capacity == 2

suite "CTUI-7: the shell paints the pane into the `state` rectangle":

  test "the state rectangle carries this pane, stacked and unstacked":
    ## TWO GEOMETRIES, because the `state` rectangle has TWO SHAPES and the
    ## painting rule differs between them. Measured on this tree (2026-09-06):
    ## the Compact profile puts `state` in a TAB STACK — `Variables` beside
    ## `Timeline` and `Tracepoints` — so CTUI-3's tab strip owns the first row
    ## and the pane owns what is below it; the Standard and Ultra-wide profiles
    ## give it a rectangle of its own, and the pane owns all of it including its
    ## own title row.
    ##
    ## A test that checked only one of them would leave the other painting
    ## either over the tab strip or one row short, and both are screens nobody
    ## would look at twice.
    var checkedGeometries = 0
    for geometry in [(cols: 80, rows: 24), (cols: 200, rows: 60)]:
      inc checkedGeometries
      let nodes = @[
        VarNode(path: "@Locals.counter", name: "counter", typeName: "Int",
                value: "41"),
        VarNode(path: "@Locals.total", name: "total", typeName: "Int",
                value: "306"),
      ]
      var model = initVariablesModel(
        scopes = @[Scope(kind: skLocals, availability: savaAvailable)],
        children = sampleChildren(nodes))
      model.expandNode(scopePath(skLocals))
      ck model.heldNodes(scopePath(skLocals)) == nodes.len

      # THE EMPTY MODEL LEAVES CTUI-3'S SCREEN ALONE, which is what keeps every
      # earlier golden readable. Asserted FIRST, and over the whole screen
      # rather than over one row.
      var plain = newShellModel(geometry.cols, geometry.rows)
      let before = shellRows(plain, geometry.cols, geometry.rows)
      var filled = plain
      filled.variables = model
      let after = shellRows(filled, geometry.cols, geometry.rows)
      let body = bodyArea(geometry.cols, geometry.rows)
      let projection = projectLayout(filled.layout, body)
      var paneRegion = PaneRegion(activeTab: -1)
      for r in projection.regions:
        if r.pane == paneState:
          paneRegion = r
      let area = paneRegion.area
      let stacked = paneRegion.activeTab >= 0
      checkpoint($geometry.cols & "x" & $geometry.rows & " state rectangle: " &
                 "col " & $area.col & ", row " & $area.row & ", " &
                 $area.width & "x" & $area.height & ", tabs " &
                 $paneRegion.tabs & ", active " & $paneRegion.activeTab)
      ck area.width > 0
      ck area.height > 1
      ck before.len == after.len

      let paneTop = if stacked: area.row + 1 else: area.row
      let paneHeight = if stacked: area.height - 1 else: area.height
      let flushRight = area.col + area.width >= body.col + body.width
      let inner = if flushRight: area.width else: area.width - 1
      let paneRowsText = variablesText(model, inner, paneHeight)

      var changedRows = 0
      var outsideChanges = 0
      for i in 0 ..< before.len:
        if before[i] != after[i]:
          inc changedRows
          if i < area.row or i >= area.row + area.height:
            inc outsideChanges
      checkpoint("rows the pane changed: " & $changedRows & ", outside the " &
                 "rectangle: " & $outsideChanges)
      # A pane that painted nowhere and a pane that painted everywhere both fail
      # this pair.
      ck changedRows > 0
      ck changedRows <= area.height
      ck outsideChanges == 0

      var matched = 0
      var firstDiff = ""
      for i in 0 ..< paneHeight:
        var slice = ""
        var at = 0
        for r in after[paneTop + i].runes:
          let w = max(1, cellWidthOf($r))
          if at >= area.col and at < area.col + inner:
            slice.add $r
          at += w
        if slice == paneRowsText[i]:
          inc matched
        elif firstDiff.len == 0:
          firstDiff = "row " & $i & ":\n  shell: '" & slice & "'\n  pane:  '" &
            paneRowsText[i] & "'"
      if firstDiff.len > 0:
        checkpoint(firstDiff)
      checkpoint("pane rows matched: " & $matched & " of " & $paneHeight)
      ck matched == paneHeight

      # …and the rectangle's first row still says what CTUI-3 put there. On the
      # stacked shape that is the tab strip, whose title comes from the SAVED
      # LAYOUT; on the unstacked one the pane owns the row and puts its own
      # title there.
      if stacked:
        ck after[area.row].contains(paneRegion.tabs[paneRegion.activeTab])
      else:
        ck after[area.row].contains(VariablesTitle)
    ck checkedGeometries == 2

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
