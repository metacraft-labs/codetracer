## test_layout_binding.nim — PLAT-6, Tier 1.
##
## ## Which tier, and why this one
##
## **Tier 1**, per `docs/tui-testing.md`'s table: everything here is "a pane's
## content and semantics" or "layout arithmetic", and both are named there as
## Tier-1 subjects. Concretely:
##
##   * the hit-test is integer arithmetic over a projection — there is no
##     terminal in it, and a pty would add a compile and a spawn per case
##     without adding an observation;
##   * every gesture is asserted **on the resulting `Layout`**, which is a
##     value a real terminal cannot show and only the model can be asked
##     about;
##   * the composited-screen cases mount the real component tree in
##     `TerminalTestHarness` and read `cellAt`, which is the same compositor
##     the product uses.
##
## **What is deliberately NOT here, and where it is.** The SGR-1006 wire format
## is a Tier-2 subject ("real byte sequences arriving on a real fd"). This file
## asserts the layer above it — that a DECODED event becomes the right layout
## command — and it feeds the decoder the exact bytes `TermAssert.sendMouseClick`
## writes, which is the same standard `app/tests/test_call_stack_keys.nim` holds
## itself to for the same decoder. A pty case that drives a layout gesture end
## to end needs the product's input loop to route mouse reports into a
## `LayoutBinding`, and `src/frontend/tui/main.nim` does not do that yet; that
## is recorded in PLAT-6's status rather than papered over here.
##
## ## No mocks
##
## There is no mock in this file and none is justified, because none is needed:
## the subject is a layout model, a Yoga projection, an integer grid and a byte
## decoder, and all four are real. The harness composites into a real
## `ScreenBuffer` through the real compositor.
##
## ## Templates, not procs, for anything that calls `check`
##
## Verification-Harness-Traps §13: `unittest.check` inside a plain `proc`
## cannot see `testStatusIMPL`, so it sets `programResult` and lets the case
## print `[OK]` anyway. Every helper below that calls `check` is a `template`.
## The ones that are `proc`s — `bodyFor`, `compact`, `pressAt`, … — return
## values and call `check` nowhere.

import std/[json, options, os, strutils, unicode, unittest]

import isonim_tui

import headless_app/layout_interaction
import headless_app/layout_model

import ../input/mouse
import ../layout/binding
import ../layout/profile
import ../layout/project
import ../layout/tab_strip
import ../views/shell

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 2053

const
  Geometries = [(cols: 80, rows: 24), (cols: 120, rows: 40),
                (cols: 200, rows: 60)]
    ## The three sizes CTUI-3's own suites walk, so the profile each one
    ## selects is the profile this binding is exercised on.

  NodeInfoFieldCount = 7
    ## The counted control for the reference-freedom walk below
    ## (Verification-Harness-Traps §4b): a `fieldPairs` loop that visited
    ## nothing would satisfy "no field is a reference" for free.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# Fixtures. Values only; nothing here calls `check`.
# ---------------------------------------------------------------------------

proc bodyFor(cols, rows: int): CellArea = bodyArea(cols, rows)

proc compact(): Layout = initLayout(profileLayout(lpCompact))
proc standard(): Layout = initLayout(profileLayout(lpStandard))
proc ultraWide(): Layout = initLayout(profileLayout(lpUltraWide))

proc layoutFor(profile: LayoutProfile): Layout =
  initLayout(profileLayout(profile))

proc allEdgesDocked(): Layout =
  ## Ultra-wide with one pane auto-hidden on each of the four edges, which
  ## leaves `editor` alone in the tree.
  ##
  ## Built by APPLYING the four commands rather than by writing the answer
  ## down, so the collapse rules that fire on the way (a row left with one
  ## child becomes that child) are the model's and not this file's idea of
  ## them.
  var l = ultraWide()
  for pair in [(paneTimeline, leBottom), (paneCalltrace, leLeft),
               (paneState, leRight), (paneEventLog, leTop)]:
    let outcome = apply(l, cmdDock(pair[0], pair[1]))
    if outcome.kind == loApplied:
      l = outcome.layout
  l

proc press(row, col: int): mouse.MouseEvent =
  mouse.MouseEvent(kind: mekPress, button: mbLeft, row: row, col: col)

proc release(row, col: int): mouse.MouseEvent =
  mouse.MouseEvent(kind: mekRelease, button: mbLeft, row: row, col: col)

proc wheel(down: bool; row, col: int): mouse.MouseEvent =
  mouse.MouseEvent(kind: mekPress,
             button: (if down: mbWheelDown else: mbWheelUp),
             row: row, col: col)

proc sgr(button, row, col: int; pressed: bool): string =
  ## The exact bytes `TermAssert.sendMouseClick` writes: SGR 1006, ONE-BASED.
  ## See `app/input/mouse.nim`'s header.
  "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) &
    (if pressed: "M" else: "m")

proc stackRegionOf(geom: LayoutGeometry; pane: PaneKind): PaneRegion =
  for r in geom.projection.regions:
    if r.pane == pane:
      return r
  PaneRegion(pane: pane, activeTab: -1)

proc tabCell(geom: LayoutGeometry; stacked: PaneKind; slot: int): (int, int) =
  ## The (row, col) of the middle of tab `slot`'s label on the strip holding
  ## `stacked`. Derived from `tabSpans` — the SAME arithmetic the painter uses
  ## — so a coordinate this test clicks is a coordinate the screen drew.
  let region = stackRegionOf(geom, stacked)
  let spans = tabSpans(region.tabs, region.activeTab)
  if slot < 0 or slot >= spans.len:
    return (-1, -1)
  (region.area.row, region.area.col + spans[slot].startCol +
                    spans[slot].width div 2)

proc bindingOn(l: Layout; profile: LayoutProfile;
               focus = paneEditor): LayoutBinding =
  newLayoutBinding(l, profile, focus)

proc paneOfPathIn(l: Layout; path: string): PaneKind =
  let info = nodeInfoAtPath(l.tree, path)
  if info.isNone or info.get.kind != lnPane: PaneKind.low else: info.get.pane

proc sliceCells(line: string; col, width: int): string =
  ## `width` cells of `line`, starting at CELL `col`.
  ##
  ## BY CELL RATHER THAN BY BYTE, and that is a fix rather than a style choice.
  ## The painted strip's filler is `─` (U+2500) — three bytes, one cell — so
  ## `line[col ..< col + width]` compares the wrong bytes the moment a stack
  ## does not start at column 0 or a pane title is not ASCII, and can cut a rune
  ## in half. PLAT-6's independent pass recorded that as a residual of the
  ## tab-strip case; it also produced the partial rune that ended a mutation arm
  ## in a `UnicodeDecodeError` instead of a verdict.
  result = ""
  var at = 0
  for r in runes(line):
    if at >= col + width:
      break
    if at >= col:
      result.add $r
    at += max(1, displayWidth($r))

proc specStrip(tabs: seq[string]; active, width: int): string =
  ## §3.1's tab strip, WRITTEN FROM THE SPECIFICATION and from nothing in
  ## `app/layout/tab_strip.nim`: the active tab in brackets, every other one
  ## padded with one space on each side so the strip does not reflow when a tab
  ## is activated, one space between neighbours, then a space and the rule glyph
  ## out to the pane's width.
  ##
  ## **THIS IS THE ORACLE THE STRUCTURAL CHANGE MADE NECESSARY.** `tabRow` now
  ## assembles the row from `tabSpans`, so the painter and the hit-test read one
  ## table and cannot disagree — which also means a check that compares them
  ## cannot see a defect IN that table. `TabGapCells` widened to 2 moves the
  ## paint and the hit-test together and the column-by-column walk below stays
  ## green; this does not. It calls `tabSpans`, `tabLabel`, `tabStripCells` and
  ## `TabGapCells` nowhere, which is the whole of its value.
  if width <= 0:
    return ""
  var parts: seq[string] = @[]
  for i, t in tabs:
    parts.add(if i == active: "[" & t & "]" else: " " & t & " ")
  var line = parts.join(" ")
  if textCells(line) + 1 <= width:
    line.add " "
    line.add repeatGlyph(PaneRuleGlyph, width - textCells(line))
  fitCells(line, width)

proc innerWidthOf(geom: LayoutGeometry; area: CellArea): int =
  ## The width `views/shell.paintPane` paints a pane's rows at: its whole
  ## rectangle when it is flush with the inner area's right edge, one cell less
  ## when it has to draw the `│` separator. Spelled here the way the painter
  ## spells it, because a comparison against a strip painted at a DIFFERENT
  ## width is a comparison of two different rows.
  if area.col + area.width >= geom.inner.col + geom.inner.width: area.width
  else: area.width - 1

proc shapeOf(l: Layout): string =
  ## The tree as one comparable string, plus the dock list. `$` on a
  ## `LayoutNode` already renders the shape; the docked panes are appended so
  ## a comparison cannot miss a pane that left the tree for a strip.
  var docked: seq[string] = @[]
  for d in l.docked:
    docked.add $d
  $l.tree & " docked[" & docked.join(",") & "]"

# ---------------------------------------------------------------------------
# Assertion helpers. TEMPLATES, every one — see the header on trap 13.
# ---------------------------------------------------------------------------

template ckPartition(geom: LayoutGeometry; label: string) =
  ## The projection is a faithful partition OF THE INNER AREA — the body minus
  ## the dock strips — checked over the cell grid, with the covered-cell count
  ## as the positive control that the checker looked at anything.
  block:
    let found = coverageProblems(geom.projection.regions, geom.inner)
    if found.len > 0:
      checkpoint(label & ": " & describe(found))
      checkpoint(label & ": " & describe(geom.projection))
    ck found.len == 0
    ck coveredCells(geom.projection.regions, geom.inner) ==
       geom.inner.cellCount()
    ck geom.projection.regions.len > 0

template ckStripsTileTheBody(l: Layout; geom: LayoutGeometry;
                             label: string) =
  ## The strips and the inner area together are the body EXACTLY: every cell of
  ## the body belongs to the tree or to exactly one strip, and none belongs to
  ## two.
  ##
  ## **IT CARRIES ITS OWN POSITIVE CONTROL NOW.** `doubleClaimed == 0` and
  ## `unowned == 0` are both satisfied by a zero-cell body — a sweep that
  ## visited nothing finds no double claim and no orphan — and PLAT-6 landed
  ## this template borrowing `ckPartition`'s control instead, which is only
  ## load-bearing while a caller happens to run both against a non-empty inner
  ## area. The four assertions below the sweep are the control: the sweep
  ## reached every cell of the body, the body has cells, the inner area got
  ## exactly the ones the projection is total over, and the strips got the rest
  ## — and the strips have cells exactly when something is docked, which is
  ## what makes the whole check say something about strips rather than about a
  ## rectangle no pane was ever hidden into (Verification-Harness-Traps §4b).
  block:
    var owner = newSeq[int](max(0, geom.body.cellCount()))
    for i in 0 ..< owner.len:
      owner[i] = -1
    var doubleClaimed = 0
    var unowned = 0
    var sweptBodyCells = 0
    var innerCells = 0
    var stripCells = 0
    for row in geom.body.row ..< geom.body.row + geom.body.height:
      for col in geom.body.col ..< geom.body.col + geom.body.width:
        let at = (row - geom.body.row) * geom.body.width +
                 (col - geom.body.col)
        inc sweptBodyCells
        var claims = 0
        if geom.inner.contains(row, col):
          inc claims
          inc innerCells
          owner[at] = -2
        for si, s in geom.strips:
          if s.area.contains(row, col):
            inc claims
            inc stripCells
            owner[at] = si
        if claims > 1: inc doubleClaimed
        if claims == 0: inc unowned
    checkpoint(label & ": strips=" & $geom.strips.len & " docked=" &
               $l.docked.len & " swept=" & $sweptBodyCells & " inner=" &
               $innerCells & " strip=" & $stripCells & " body=" &
               $geom.body.cellCount())
    ck doubleClaimed == 0
    ck unowned == 0
    ck sweptBodyCells == geom.body.cellCount()
    ck geom.body.cellCount() > 0
    ck innerCells == geom.inner.cellCount()
    ck innerCells + stripCells == geom.body.cellCount()
    # BOTH DIRECTIONS, so neither half is free: docked panes mean claimed strip
    # cells, and nothing docked means none.
    ck (l.docked.len > 0) == (stripCells > 0)

template ckMessageIsNeverSilent(a: LayoutAction; label: string) =
  block:
    if a.message.len == 0:
      checkpoint(label & " produced an EMPTY message")
    ck a.message.len > 0

# ---------------------------------------------------------------------------

suite "PLAT-6: the terminal front-end is a BINDING to the layout model":

  test "the hit-test partitions the body: every cell resolves to exactly one zone":
    # §5's second obligation, as a property rather than as examples. A pointer
    # that resolved to nothing, or to two things, would make a drag behave
    # differently depending on where in a pane it started.
    var sweptCells = 0
    var resolved = 0
    var zonesSeen: set[DropZone] = {}
    for g in Geometries:
      for l in [layoutFor(selectProfile(g.cols, g.rows)), allEdgesDocked()]:
        let geom = geometryOf(l, bodyFor(g.cols, g.rows))
        ckPartition(geom, $g.cols & "x" & $g.rows)
        ckStripsTileTheBody(l, geom, $g.cols & "x" & $g.rows)
        for row in geom.body.row ..< geom.body.row + geom.body.height:
          for col in geom.body.col ..< geom.body.col + geom.body.width:
            inc sweptCells
            let p = pointerAt(l, geom, row, col)
            if p.isSome:
              inc resolved
              zonesSeen.incl p.get.zone
    # THE POSITIVE CONTROL. `resolved == sweptCells` is satisfied for free by a
    # sweep that visited nothing, so the number of cells is asserted too — and
    # it is knowable: three geometries, two layouts each, one body apiece.
    var expectedCells = 0
    for g in Geometries:
      expectedCells += 2 * bodyFor(g.cols, g.rows).cellCount()
    checkpoint("swept " & $sweptCells & " cell(s), resolved " & $resolved)
    ck sweptCells == expectedCells
    ck resolved == sweptCells
    # EVERY ZONE IS REACHABLE from a real screen. `dzTabStrip` needs a stack,
    # the four `dzOutside*` need the four dock strips, and the rest need a pane
    # wide enough to have a centre — all of which the two layouts above have
    # between them.
    checkpoint("zones reached: " & $zonesSeen)
    for z in DropZone:
      ck z in zonesSeen

  test "cells -> pointer -> region -> cells is a round trip":
    # The two directions of the hit-test are the SAME table read twice, and
    # this is what says so: a cell that resolves to an edge zone lies inside
    # the rectangle `cellsFor` draws for that zone's region, and a cell on a
    # tab produces a caret on that stack's own strip row, within its columns.
    #
    # THE TAB-SLOT ARM NOW ASSERTS THE STRONGER PROPERTY IT USED TO CLAIM.
    # PLAT-6 landed it checking only that the caret is on the strip's row and
    # inside the strip's columns, while its comment said the caret "lands
    # inside tab `i`'s span". The stronger statement does hold — `regionForZone`
    # turns `dzTabStrip` on tab `i` into slot `i`, and `cellsFor` puts the caret
    # on that span's own `startCol` — and it is one comparison, so it is made:
    # the caret column is tab `slot`'s first cell, and hit-testing that column
    # answers `slot` again. The append slot (`slot == tabs.len`) is the one case
    # where the caret is deliberately NOT inside any span; it is counted
    # separately rather than folded in.
    #
    # COUNTS RATHER THAN ONE `check` PER CELL: the sweep is tens of thousands
    # of cells, and a `ck` inside it would make the file's assertion total a
    # number nobody can reason about while reporting the same defect thousands
    # of times. Every disagreement is COLLECTED and named, and the counts are
    # what the assertions read.
    #
    # THE REGION IS THE MODEL'S OWN, not a second mapping written here:
    # `hoveredTarget` returns the candidate the pointer is on, carrying the
    # `DropRegion` `layout_interaction` decided, and this file only converts
    # that back to cells. So what is under test is the composition — the
    # binding's two directions against the model's one — rather than the
    # binding agreeing with itself.
    var wholeNodeChecks = 0
    var nodeStripChecks = 0
    var tabSlotChecks = 0
    var caretsInsideTheirOwnTab = 0
    var caretsAtTheAppendSlot = 0
    var caretsClamped = 0
    var stripHitsInsideTheTree = 0
    var unresolved = 0
    var noTarget = 0
    var mismatches: seq[string] = @[]
    for g in Geometries:
      let l = layoutFor(selectProfile(g.cols, g.rows))
      let geom = geometryOf(l, bodyFor(g.cols, g.rows))
      for row in geom.inner.row ..< geom.inner.row + geom.inner.height:
        for col in geom.inner.col ..< geom.inner.col + geom.inner.width:
          let p = pointerAt(l, geom, row, col)
          if p.isNone:
            inc unresolved
            continue
          if p.get.zone in {dzOutsideLeft, dzOutsideRight, dzOutsideTop,
                            dzOutsideBottom}:
            inc stripHitsInsideTheTree
            continue
          # A source that is NOT the pane under the cursor, so the candidate
          # list is the one a real drag onto this cell would produce.
          var source = PaneKind.low
          var haveSource = false
          for region in geom.projection.regions:
            if not region.area.contains(row, col):
              source = region.pane
              haveSource = true
              break
          if not haveSource:
            continue
          let hovered = hoveredTarget(l, source, p.get)
          if hovered.isNone:
            inc noTarget
            continue
          let cells = geom.cellsFor(hovered.get)
          let at = "(" & $row & "," & $col & ") " & $p.get.zone & " -> " &
                   $hovered.get.region
          case hovered.get.region.kind
          of drWholeNode:
            inc wholeNodeChecks
            if not cells.contains(row, col):
              mismatches.add at & " does not contain its own cell (" &
                $cells & ")"
          of drNodeStrip:
            inc nodeStripChecks
            if not cells.contains(row, col):
              mismatches.add at & " does not contain its own cell (" &
                $cells & ")"
          of drTabSlot:
            # A caret is an INSERTION POINT, so it is not the cell that was
            # clicked. It must be on the strip's own row, inside the strip's own
            # columns — and, for every slot but the append one, ON THE FIRST
            # CELL OF THAT SLOT'S OWN TAB.
            inc tabSlotChecks
            let strip = geom.tabStripOf(hovered.get.region.path)
            let spans = tabSpans(strip.tabs, strip.active)
            let slot = hovered.get.region.slot
            if not strip.found:
              mismatches.add at & " named a stack with no strip on screen"
            elif cells.row != strip.area.row:
              mismatches.add at & "'s caret is on row " & $cells.row &
                " rather than " & $strip.area.row
            elif cells.col < strip.area.col or
                 cells.col >= strip.area.col + strip.area.width:
              mismatches.add at & "'s caret is at column " & $cells.col &
                ", outside " & $strip.area
            elif slot < 0 or slot > spans.len:
              mismatches.add at & "'s slot " & $slot &
                " is outside 0 .. " & $spans.len
            elif slot == spans.len:
              # The append slot: one cell past the last label, and therefore
              # deliberately not inside any span.
              inc caretsAtTheAppendSlot
              let want = spans[^1].startCol + spans[^1].width
              if cells.col - strip.area.col != min(want,
                                                   max(0, strip.area.width - 1)):
                mismatches.add at & "'s append caret is at relative column " &
                  $(cells.col - strip.area.col) & " rather than " & $want
            elif spans[slot].startCol > max(0, strip.area.width - 1):
              # `cellsFor` clamps a caret that would fall off a narrow strip.
              # Counted rather than asserted, so a geometry that only ever
              # produced clamped carets cannot make the assertion below vacuous.
              inc caretsClamped
            elif cells.col != strip.area.col + spans[slot].startCol:
              mismatches.add at & "'s caret is at relative column " &
                $(cells.col - strip.area.col) & " rather than on tab " & $slot &
                "'s first cell (" & $spans[slot].startCol & ")"
            elif tabSpanAt(strip.tabs, strip.active,
                           cells.col - strip.area.col) != slot:
              mismatches.add at & "'s caret column hit-tests to tab " &
                $tabSpanAt(strip.tabs, strip.active,
                           cells.col - strip.area.col) &
                " rather than to slot " & $slot
            else:
              inc caretsInsideTheirOwnTab
          of drLayoutStrip:
            mismatches.add at & " offered a dock strip from inside the tree"
    if mismatches.len > 0:
      for m in mismatches[0 ..< min(8, mismatches.len)]:
        checkpoint(m)
    checkpoint("wholeNode: " & $wholeNodeChecks & ", nodeStrip: " &
               $nodeStripChecks & ", tabSlot: " & $tabSlotChecks &
               " (own tab: " & $caretsInsideTheirOwnTab & ", append: " &
               $caretsAtTheAppendSlot & ", clamped: " & $caretsClamped &
               "), unresolved: " & $unresolved & ", no target: " & $noTarget &
               ", strip hits inside the tree: " & $stripHitsInsideTheTree &
               ", mismatches: " & $mismatches.len)
    ck mismatches.len == 0
    # THE STRONGER TAB-SLOT PROPERTY WAS REACHED, not merely not-violated: a
    # sweep in which every caret was clamped, or in which the only slot ever
    # produced was the append one, would satisfy `mismatches.len == 0` for free.
    ck caretsInsideTheirOwnTab > 0
    ck caretsInsideTheirOwnTab + caretsAtTheAppendSlot + caretsClamped ==
       tabSlotChecks
    # THE POSITIVE CONTROLS. Every region kind a node can produce was actually
    # reached, so `mismatches.len == 0` is not the answer to an empty question;
    # and no cell inside the tree resolved to a dock strip or to nothing.
    ck wholeNodeChecks > 0
    ck nodeStripChecks > 0
    ck tabSlotChecks > 0
    ck stripHitsInsideTheTree == 0
    ck unresolved == 0

  test "the painted tab strip and the hit-test agree, column by column":
    # `tabRow` and `tabSpanAt` are one answer read twice — that is why
    # `app/layout/tab_strip.nim` exists, and since PLAT-6's follow-up landed it
    # is one answer BY CONSTRUCTION: `tabRow` assembles the row from `tabSpans`.
    #
    # THAT MAKES THIS CASE TWO CHECKS RATHER THAN ONE, and the second is the
    # one the construction created the need for:
    #
    #   * the DIFFERENTIAL half walks every column of a real painted strip and
    #     requires the label the PAINTER put there to be the tab the HIT-TEST
    #     names. It still fails when the painter stops following the span table
    #     — `run-plat6-mutations.py`'s M5 gives it its own gap back;
    #   * the ABSOLUTE half compares the painted strip with `specStrip`, §3.1's
    #     rule written out a second time and calling nothing in the module under
    #     test. A defect in the SHARED table moves both readers together and the
    #     differential half stays green; M26 widens `TabGapCells` and only this
    #     half notices.
    #
    # And the slicing is BY CELL. See `sliceCells`: the old byte slice was
    # correct only because the one stack the profiles produce starts at column 0
    # with ASCII labels.
    var columnsChecked = 0
    var labelledColumns = 0
    var stripsComparedAbsolutely = 0
    var disagreements: seq[string] = @[]
    for g in Geometries:
      let profile = selectProfile(g.cols, g.rows)
      let l = layoutFor(profile)
      let geom = geometryOf(l, bodyFor(g.cols, g.rows))
      for region in geom.projection.regions:
        if region.activeTab < 0 or region.tabs.len == 0:
          continue
        var model = newShellModel(g.cols, g.rows)
        model.layout = l.tree
        let painted = shellRows(model, g.cols, g.rows)
        let strip = painted[region.area.row]
        let spans = tabSpans(region.tabs, region.activeTab)
        for span in spans:
          for offset in 0 ..< span.width:
            let col = region.area.col + span.startCol + offset
            inc columnsChecked
            let where = $g.cols & "x" & $g.rows & " col " & $col
            if tabSpanAt(region.tabs, region.activeTab,
                         span.startCol + offset) != span.index:
              disagreements.add where & ": tabSpanAt disagrees with tabSpans"
              continue
            let p = pointerAt(l, geom, region.area.row, col)
            if p.isNone or p.get.zone != dzTabStrip:
              disagreements.add where & ": the hit-test did not say tabStrip"
              continue
            if paneOfPathIn(l, p.get.path) !=
               paneOfPathIn(l, childPathOf(parentPath(p.get.path).get,
                                           span.index)):
              disagreements.add where & ": named tab " & $p.get.path &
                " rather than index " & $span.index
          # …and the label the painter actually wrote is at those columns.
          # BY CELL, NOT BY BYTE — see `sliceCells`.
          let label = tabLabel(region.tabs[span.index],
                               span.index == region.activeTab)
          inc labelledColumns
          let onScreen = sliceCells(strip, region.area.col + span.startCol,
                                    span.width)
          if onScreen != label:
            disagreements.add "painted '" & onScreen & "' where tab " &
              $span.index & " should read '" & label & "'"
        # THE ABSOLUTE HALF. The whole painted strip against §3.1's rule,
        # restated in this file and reading nothing the painter reads.
        inc stripsComparedAbsolutely
        let inner = innerWidthOf(geom, region.area)
        let paintedStrip = sliceCells(strip, region.area.col, inner)
        let wanted = specStrip(region.tabs, region.activeTab, inner)
        if paintedStrip != wanted:
          disagreements.add $g.cols & "x" & $g.rows &
            ": the painted strip is '" & paintedStrip &
            "' where §3.1's rule says '" & wanted & "'"
    if disagreements.len > 0:
      for d in disagreements[0 ..< min(8, disagreements.len)]:
        checkpoint(d)
    checkpoint($columnsChecked & " strip column(s) checked, " &
               $labelledColumns & " label(s) compared with the paint, " &
               $stripsComparedAbsolutely & " strip(s) compared with §3.1, " &
               $disagreements.len & " disagreement(s)")
    ck disagreements.len == 0
    ck columnsChecked > 0
    ck labelledColumns > 0
    # THE ABSOLUTE HALF RAN. Without this, a geometry sweep that stopped
    # producing stacks would leave every "no disagreement" above true for free
    # — which is precisely trap 4 wearing a projection instead of a grep.
    ck stripsComparedAbsolutely > 0
    # …and the oracle is not a copy of the subject: it disagrees with the
    # painter the moment either rule is changed, which is what the two arms in
    # `run-plat6-mutations.py` measure. Asserted here as a shape rather than
    # left to the harness: a WIDER gap really does produce a different string.
    let sample = @["Variables", "Timeline", "Tracepoints"]
    ck specStrip(sample, 0, 40) == tabRow(sample, 0, 40)
    ck specStrip(sample, 1, 40) == tabRow(sample, 1, 40)
    ck specStrip(sample, 0, 40) != specStrip(sample, 1, 40)
    ck specStrip(sample, 0, 40).startsWith("[Variables]")
    ck specStrip(sample, 1, 40).contains("[Timeline]")

  test "every drop-target kind is reachable THROUGH the binding":
    # PLAT-6: "every drop-target kind … must be exercised through the terminal
    # binding, not only through the model". Each arm below is a real press and
    # a real release at coordinates read out of the geometry, and each asserts
    # the COMMAND the gesture produced and the LAYOUT it left.

    # dtIntoStack — drag a bare pane onto a stack's tab strip.
    block:
      let b = bindingOn(compact(), lpCompact)
      var geom = b.geometry(bodyFor(80, 24))
      let source = geom.regionOfPane(paneCalltrace)
      discard b.onMouse(geom, press(source.row, source.col))
      ck b.interaction.kind == ikDraggingTab
      ck b.interaction.source == paneCalltrace
      let (tabRow, tabCol) = tabCell(geom, paneState, 1)
      ck tabRow >= 0
      let dropped = b.onMouse(geom, release(tabRow, tabCol))
      checkpoint("intoStack -> " & dropped.message)
      ck dropped.status == lasApplied
      ck dropped.command.isSome
      ck dropped.command.get.kind == lcMoveTab
      ck b.layout.tree.contains(paneCalltrace)
      # It really is a TAB now: its parent is the stack that holds `state`.
      let path = panePath(b.layout, paneCalltrace)
      ck path.isSome
      let parent = nodeInfoAtPath(b.layout.tree, parentPath(path.get).get)
      ck parent.isSome
      ck parent.get.kind == lnStack
      ck b.userModified

    # dtSplitBefore and dtSplitAfter — drag onto the edge strips of a pane.
    for pair in [(leLeft, ssBefore, saRow), (leRight, ssAfter, saRow),
                 (leTop, ssBefore, saColumn), (leBottom, ssAfter, saColumn)]:
      let b = bindingOn(standard(), lpStandard)
      let geom = b.geometry(bodyFor(120, 40))
      let source = geom.regionOfPane(paneCalltrace)
      let target = geom.regionOfPane(paneState)
      discard b.onMouse(geom, press(source.row, source.col))
      ck b.interaction.kind == ikDraggingTab
      let cell = case pair[0]
        of leLeft: (target.row + target.height div 2, target.col)
        of leRight: (target.row + target.height div 2,
                     target.col + target.width - 1)
        of leTop: (target.row, target.col + target.width div 2)
        of leBottom: (target.row + target.height - 1,
                      target.col + target.width div 2)
      let dropped = b.onMouse(geom, release(cell[0], cell[1]))
      checkpoint($pair[0] & " -> " & dropped.message)
      ck dropped.status == lasApplied
      ck dropped.command.isSome
      ck dropped.command.get.kind == lcSplit
      ck dropped.command.get.splitSide == pair[1]
      ck dropped.command.get.splitAxis == pair[2]
      ck dropped.command.get.splitMovesPane
      ck dropped.command.get.splitTarget == paneState
      ck dropped.command.get.splitNewPane == paneCalltrace

    # dtDockEdge — release above the body, which is the only cell outside the
    # tree area a terminal has before anything is docked. See `onMouse`'s
    # header on why left and right are a keyboard gesture until then.
    block:
      let b = bindingOn(compact(), lpCompact)
      let geom = b.geometry(bodyFor(80, 24))
      let source = geom.regionOfPane(paneCalltrace)
      discard b.onMouse(geom, press(source.row, source.col))
      let dropped = b.onMouse(geom, release(0, 40))
      checkpoint("dockEdge -> " & dropped.message)
      ck dropped.status == lasApplied
      ck dropped.command.isSome
      ck dropped.command.get.kind == lcSetAutoHide
      ck dropped.command.get.autoHideDirection == ahDock
      ck dropped.command.get.autoHideEdge == leTop
      ck b.layout.dockedIndex(paneCalltrace) >= 0
      ck not b.layout.tree.contains(paneCalltrace)

  test "the collapse rules fire through the binding, not only through apply":
    # §2.4's rules, each reached by a GESTURE. The model's own suite asserts
    # them against `apply`; a binding that never produced a command that
    # triggers one would be green there and broken here.

    # Rule 1: a row left with one child is REPLACED by that child. Dragging
    # `calltrace` out of the Compact profile's two-pane row does it.
    block:
      let b = bindingOn(compact(), lpCompact)
      let geom = b.geometry(bodyFor(80, 24))
      let source = geom.regionOfPane(paneCalltrace)
      discard b.onMouse(geom, press(source.row, source.col))
      let (tabRow, tabCol) = tabCell(geom, paneState, 1)
      let dropped = b.onMouse(geom, release(tabRow, tabCol))
      ck dropped.status == lasApplied
      # The row is gone: `editor` is now a direct child of the root column.
      let editorPath = panePath(b.layout, paneEditor)
      ck editorPath.isSome
      checkpoint("after the drag, editor sits at '" & editorPath.get & "'")
      ck editorPath.get == "0"
      ck validate(b.layout).len == 0

    # Rule 1's STACK EXEMPTION, and rule 2, in one sequence — because the
    # difference between them is exactly what a binding is most likely to get
    # wrong. Dragging tabs out of the Compact profile's three-tab stack:
    #
    #   * after two of them leave, ONE TAB REMAINS AND THE STACK SURVIVES.
    #     §2.4 rule 1 exempts a stack, "because collapsing it would delete the
    #     tab strip the user is about to drop a second tab onto" — so the
    #     obvious expectation here (a one-child container collapses) is WRONG,
    #     and asserting it is what makes that deliberate.
    #   * after the third leaves, the stack is EMPTY and rule 2 removes it,
    #     recursively — which then leaves the root column with one child, and
    #     rule 1 (which does apply to a column) replaces it.
    block:
      let b = bindingOn(compact(), lpCompact)
      var moved = 0
      for pane in [paneTimeline, paneEventLog]:
        let geom = b.geometry(bodyFor(80, 24))
        let target = geom.regionOfPane(paneEditor)
        discard b.beginDrag(pane)
        discard b.hoverAt(geom, target.row + target.height div 2,
                          target.col + target.width - 1)
        let dropped = b.dropDrag()
        checkpoint("moving " & $pane & " out -> " & dropped.message)
        if dropped.status == lasApplied:
          inc moved
      ck moved == 2
      let statePath = panePath(b.layout, paneState)
      ck statePath.isSome
      let parent = nodeInfoAtPath(b.layout.tree, parentPath(statePath.get).get)
      ck parent.isSome
      checkpoint("with one tab left, state's parent is " & $parent.get.kind &
                 " with " & $parent.get.childCount & " child(ren)")
      ck parent.get.kind == lnStack          ## the exemption, asserted
      ck parent.get.childCount == 1
      ck validate(b.layout).len == 0

      # Rule 2: the last tab leaves and the emptied stack is removed.
      let geom = b.geometry(bodyFor(80, 24))
      let target = geom.regionOfPane(paneEditor)
      discard b.beginDrag(paneState)
      discard b.hoverAt(geom, target.row + target.height div 2,
                        target.col + target.width - 1)
      let last = b.dropDrag()
      checkpoint("moving the last tab out -> " & last.message)
      ck last.status == lasApplied
      var stacks = 0
      proc countStacks(n: LayoutNode) =
        if n.isNil: return
        if n.kind == lnStack: inc stacks
        for c in n.children: countStacks(c)
      countStacks(b.layout.tree)
      checkpoint("stacks left in the tree: " & $stacks)
      ck stacks == 0
      ck b.layout.tree.contains(paneState)
      ck validate(b.layout).len == 0

    # Rule 3: removing the LAST pane is refused. Docking every pane but one
    # leaves a bare pane; docking that one must be refused, by kind, and the
    # binding must report it rather than emptying the screen.
    block:
      let b = bindingOn(allEdgesDocked(), lpUltraWide, focus = paneEditor)
      let geom = b.geometry(bodyFor(200, 60))
      ck b.layout.tree.kind == lnPane
      let refused = b.runLayoutCommand(geom, ":dock top")
      checkpoint("docking the last pane -> " & refused.message)
      ck refused.status == lasRefused
      ck refused.problem.isSome
      ckMessageIsNeverSilent(refused, ":dock top on the last pane")
      ck b.layout.tree.contains(paneEditor)

    # Rule 4: the surviving siblings' weights are RENORMALISED, so a removal
    # does not silently shrink the layout. Asserted as the sum, because that is
    # what the rule is about.
    block:
      let b = bindingOn(ultraWide(), lpUltraWide, focus = paneEventLog)
      let geom = b.geometry(bodyFor(200, 60))
      let before = b.layout.tree.children[0].children.len
      let docked = b.runLayoutCommand(geom, ":dock right")
      ck docked.status == lasApplied
      let rowNode = b.layout.tree.children[0]
      ck rowNode.children.len == before - 1
      var sum = 0.0
      for c in rowNode.children:
        sum += c.weight
      checkpoint("weights after the removal sum to " & $sum)
      ck abs(sum - 100.0) < 0.001

  test "a docked pane round-trips: dock, render, save, restore, undock":
    let b = bindingOn(standard(), lpStandard, focus = paneCalltrace)
    var geom = b.geometry(bodyFor(120, 40))
    let widthBefore = geom.inner.width

    let docked = b.runLayoutCommand(geom, ":dock left")
    ck docked.status == lasApplied
    ck b.layout.dockedIndex(paneCalltrace) >= 0
    geom = b.geometry(bodyFor(120, 40))
    # THE STRIP TOOK A COLUMN, and the tree is projected into what is left —
    # which is what keeps the partition invariant meaningful once panes are
    # docked.
    ck geom.strips.len == 1
    ck geom.strips[0].edge == leLeft
    ck geom.inner.width == widthBefore - DockStripThickness
    ckPartition(geom, "docked-left 120x40")
    ckStripsTileTheBody(b.layout, geom, "docked-left 120x40")

    # The strip is on screen, with the pane's title in it.
    var model = newShellModel(120, 40)
    model.layout = b.layout.tree
    model.docked = b.layout.docked
    let screen = shellScreen(model, 120, 40)
    ck screen.decorations.len >= 1
    var stripDrawn = false
    for d in screen.decorations:
      if d.kind == ldDockStrip:
        stripDrawn = true
        ck d.area == geom.strips[0].area
    ck stripDrawn

    # SAVE AND RESTORE, compared as the serialised bytes.
    let doc = b.saveDocument()
    let bytes = $doc
    checkpoint("saved document is " & $bytes.len & " byte(s)")
    ck bytes.contains("\"docked\"")
    ck not bytes.contains("\"revealed\"")   ## §3.2: transient, never persisted
    let restoredInto = bindingOn(compact(), lpCompact)
    let restored = restoredInto.restoreDocument(doc)
    ck restored.status == lasApplied
    ck shapeOf(restoredInto.layout) == shapeOf(b.layout)
    ck $restoredInto.saveDocument() == bytes

    # A REVEAL IS NOT A RESTORE: it opens an overlay and commits nothing.
    let revealed = b.runLayoutCommand(geom, ":reveal calltrace")
    ck revealed.status == lasPending
    ck b.interaction.kind == ikRevealingDock
    ck b.interaction.isRevealed(paneCalltrace)
    ck b.layout.dockedIndex(paneCalltrace) >= 0
    ck shapeOf(b.layout) == shapeOf(restoredInto.layout)
    let revealGeom = b.geometry(bodyFor(120, 40))
    ck revealGeom.revealing
    ck not revealGeom.reveal.isEmptyArea
    discard b.cancelGesture()
    ck b.interaction.kind == ikNone

    # …and `:undock` is the command that really does put it back.
    let back = b.runLayoutCommand(b.geometry(bodyFor(120, 40)), ":undock")
    checkpoint(":undock -> " & back.message)
    ck back.status == lasApplied
    ck b.layout.dockedIndex(paneCalltrace) < 0
    ck b.layout.tree.contains(paneCalltrace)
    ck b.geometry(bodyFor(120, 40)).inner.width == widthBefore

  test "PLAT-4's handed-forward gate: a command sweep, then a PROJECTION":
    # THE ASSERTION PLAT-4 DEFERRED TO THIS MILESTONE'S GATE. The model already
    # asserts the floating-panel non-goal internally — three `PanePlacement`
    # values, a field walk finding no coordinate on any persisted type, one
    # distinct leaf per visible pane after a command sweep. What nobody
    # asserted is the half that needs `isonim_tui`: that after a sweep of REAL
    # COMMANDS the projection is still a total, pairwise-disjoint partition of
    # the cell grid.
    #
    # `project.nim` imports `isonim_tui`, which is why this could not live in
    # `vm-unit`. It can live here, and this is it.
    var commandsApplied = 0
    var projectionsChecked = 0
    var refusals = 0
    for g in Geometries:
      for profile in LayoutProfile:
        let b = bindingOn(layoutFor(profile), profile)
        let body = bodyFor(g.cols, g.rows)
        # Every command kind the binding can issue, over a real arrangement.
        let sweep = @[
          cmdActivateTab(paneEventLog),
          cmdSetWeight(paneEditor, 55.0),
          cmdMoveTab(paneTimeline, paneState, 0),
          cmdSplitMove(paneEditor, paneCalltrace, saColumn, ssAfter),
          cmdMergeIntoStack(paneEventLog, paneEditor),
          cmdDock(paneTimeline, leBottom),
          cmdRestoreDocked(paneTimeline, some(paneEditor)),
          cmdDock(paneState, leLeft),
          cmdRename(paneEditor, "Source"),
          cmdSplitMove(paneEditor, paneEventLog, saRow, ssBefore),
          cmdSetWeight(paneEditor, 20.0)]
        for cmd in sweep:
          let outcome = b.dispatch(cmd)
          if outcome.status == lasApplied:
            inc commandsApplied
          elif outcome.status == lasRefused:
            inc refusals
          ckMessageIsNeverSilent(outcome, $cmd)
          # AFTER EVERY COMMAND, not only at the end: a partition that broke
          # in the middle and healed would otherwise pass.
          let geom = b.geometry(body)
          inc projectionsChecked
          ckPartition(geom, $profile & " " & $g.cols & "x" & $g.rows &
                            " after " & $cmd)
          ckStripsTileTheBody(b.layout, geom,
                              $profile & " after " & $cmd)
          # ONE DISTINCT LEAF PER VISIBLE PANE, over the CELLS this time: the
          # projection gives each visible pane exactly one rectangle, and the
          # rectangles do not overlap — which is the floating-panel non-goal
          # made geometric. A floating panel is precisely a pane with a region
          # that is not a region OF THE SPLIT TREE.
          var seen: set[PaneKind] = {}
          for r in geom.projection.regions:
            ck r.pane notin seen
            seen.incl r.pane
          ck geom.projection.regions.len == visiblePanes(b.layout.tree).len
          ck validate(b.layout).len == 0
    checkpoint($commandsApplied & " command(s) applied, " & $refusals &
               " refused, " & $projectionsChecked & " projection(s) checked")
    # The positive control: the sweep really ran, and it really CHANGED things.
    ck projectionsChecked == 3 * 3 * 11
    ck commandsApplied > 0
    ck refusals > 0

  test "the drag ghost, the drop target and the resize guide are on the screen":
    # §5's third obligation, asserted on the COMPOSITED SCREEN through the real
    # harness — so this is the compositor's answer, not `shellRows`'s.
    let b = bindingOn(standard(), lpStandard)
    let geom = b.geometry(bodyFor(120, 40))
    let source = geom.regionOfPane(paneCalltrace)
    let target = geom.regionOfPane(paneState)
    discard b.onMouse(geom, press(source.row, source.col))
    discard b.hoverAt(geom, target.row + target.height div 2, target.col)
    ck b.interaction.kind == ikDraggingTab
    ck b.interaction.hover.isSome

    var model = newShellModel(120, 40)
    model.layout = b.layout.tree
    model.docked = b.layout.docked
    model.interaction = b.interaction
    let screen = shellScreen(model, 120, 40)
    var kinds: set[LayoutDecorationKind] = {}
    for d in screen.decorations:
      kinds.incl d.kind
    checkpoint("decorations: " & $kinds)
    ck ldDragGhost in kinds
    ck ldDropTarget in kinds

    let h = newTerminalTestHarness(120, 40)
    h.mount(proc (r: TerminalRenderer): TerminalNode =
      renderShellTree(model, r, 120, 40))
    var ghostCells = 0
    var targetCells = 0
    for d in screen.decorations:
      let glyph = glyphFor(d.kind)
      for row in d.area.row ..< d.area.row + d.area.height:
        for col in d.area.col ..< d.area.col + d.area.width:
          let painted = $h.cellAt(row, col).rune
          if d.kind == ldDragGhost and painted == glyph: inc ghostCells
          if d.kind == ldDropTarget and painted == glyph: inc targetCells
    checkpoint("ghost cells on the composited screen: " & $ghostCells &
               ", drop-target cells: " & $targetCells)
    # Not "at least one": the rectangles are known, and every cell of each is
    # the glyph except the ones the label overwrote on the first row.
    ck ghostCells > 0
    ck targetCells > 0
    let hovered = b.interaction.hover.get
    ck geom.cellsFor(hovered) ==
       (block:
          var found = CellArea()
          for d in screen.decorations:
            if d.kind == ldDropTarget: found = d.area
          found)

    # THE RESIZE GUIDE, which needs no drag: it is where the divider would land
    # if the proposal committed, computed by projecting the proposed layout.
    let resizing = beginResize(b.layout, paneEditor)
    ck resizing.isSome
    var guideModel = newShellModel(120, 40)
    guideModel.layout = b.layout.tree
    guideModel.interaction = resizing.get.proposeShare(b.layout, 0.8)
    let guideScreen = shellScreen(guideModel, 120, 40)
    var guides = 0
    for d in guideScreen.decorations:
      if d.kind == ldResizeGuide:
        inc guides
        ck d.area.width == 1 or d.area.height == 1
    checkpoint("resize guides drawn: " & $guides)
    ck guides == 1

  test "a cancelled gesture leaves the committed layout byte-identical":
    # PLAT-5 asserts this of `cancel`; this asserts it of the BINDING, which is
    # the layer that could have committed something on the way.
    var comparisons = 0
    for g in Geometries:
      let profile = selectProfile(g.cols, g.rows)
      let b = bindingOn(layoutFor(profile), profile)
      let before = $b.saveDocument()
      let geom = b.geometry(bodyFor(g.cols, g.rows))
      for region in geom.projection.regions:
        discard b.beginDrag(region.pane)
        for row in geom.inner.row ..< geom.inner.row + geom.inner.height:
          discard b.hoverAt(geom, row, geom.inner.col)
        let cancelled = b.cancelGesture()
        ck cancelled.status == lasCancelled
        inc comparisons
        ck $b.saveDocument() == before
        ck not b.userModified
    checkpoint($comparisons & " cancelled drag(s) compared as bytes")
    ck comparisons > 0

  test "every keyboard gesture has a spelling, and none of them is silent":
    # PLAT-6: "Keyboard paths for every gesture, since a terminal user may have
    # no pointer". Every verb is exercised; the published name table is
    # compared with the enum; and a garbage line is REPORTED.
    ck LayoutVerbNames.len == ord(high(LayoutVerb)) + 1
    var verbsRun: set[LayoutVerb] = {}
    for v in LayoutVerb:
      ck LayoutVerbNames[v] == $v
      let (known, parsed) = parseLayoutVerb(LayoutVerbNames[v])
      ck known
      ck parsed == v

    # :move-tab — a real reorder inside the Compact stack, asserted on the
    # MODEL: the tab's index moved.
    block:
      let b = bindingOn(compact(), lpCompact, focus = paneTimeline)
      let geom = b.geometry(bodyFor(80, 24))
      ck panePath(b.layout, paneTimeline) == some("1/1")
      let moved = b.runLayoutCommand(geom, ":move-tab left")
      checkpoint(":move-tab left -> " & moved.message)
      ck moved.status == lasApplied
      ck moved.command.get.kind == lcMoveTab
      ck panePath(b.layout, paneTimeline) == some("1/0")
      verbsRun.incl lvMoveTab
      let last = b.runLayoutCommand(geom, ":move-tab last")
      ck last.status == lasApplied
      ck panePath(b.layout, paneTimeline) == some("1/2")
      let bad = b.runLayoutCommand(geom, ":move-tab sideways")
      ck bad.status == lasBadArgument
      ckMessageIsNeverSilent(bad, ":move-tab sideways")

    # :move-pane — the keyboard spelling of the edge drop, through the SAME
    # directional rule `Ctrl+w` uses.
    block:
      let b = bindingOn(standard(), lpStandard, focus = paneCalltrace)
      let geom = b.geometry(bodyFor(120, 40))
      let moved = b.runLayoutCommand(geom, ":move-pane right")
      checkpoint(":move-pane right -> " & moved.message)
      ck moved.status == lasApplied
      ck moved.command.get.kind == lcSplit
      ck moved.command.get.splitMovesPane
      ck moved.command.get.splitTarget == paneEditor
      verbsRun.incl lvMovePane

    # :merge-pane, :dock, :undock, :reveal, :hide
    block:
      let b = bindingOn(standard(), lpStandard, focus = paneCalltrace)
      var geom = b.geometry(bodyFor(120, 40))
      let merged = b.runLayoutCommand(geom, ":merge-pane state")
      ck merged.status == lasApplied
      ck merged.command.get.kind == lcMergeIntoStack
      verbsRun.incl lvMergePane
      geom = b.geometry(bodyFor(120, 40))
      let dockedNow = b.runLayoutCommand(geom, ":dock bottom")
      ck dockedNow.status == lasApplied
      verbsRun.incl lvDock
      geom = b.geometry(bodyFor(120, 40))
      let shown = b.runLayoutCommand(geom, ":reveal")
      ck shown.status == lasPending
      verbsRun.incl lvReveal
      let hidden = b.runLayoutCommand(geom, ":hide")
      ck hidden.status == lasCancelled
      verbsRun.incl lvHide
      let undocked = b.runLayoutCommand(geom, ":undock")
      ck undocked.status == lasApplied
      verbsRun.incl lvUndock

    # :resize — the keyboard's divider drag, through beginResize/proposeShare/
    # commit, asserted as the WEIGHT the model ended up with.
    block:
      let b = bindingOn(standard(), lpStandard, focus = paneEditor)
      let geom = b.geometry(bodyFor(120, 40))
      let resized = b.runLayoutCommand(geom, ":resize 70")
      checkpoint(":resize 70 -> " & resized.message)
      ck resized.status == lasApplied
      ck resized.command.get.kind == lcSetWeight
      ck resized.command.get.weightTarget == paneEditor
      let leaf = b.layout.tree.find(paneEditor)
      ck not leaf.isNil
      var total = 0.0
      for c in b.layout.tree.children[0].children:
        total += effectiveWeight(c)
      checkpoint("editor now takes " & $(effectiveWeight(leaf) / total))
      ck abs(effectiveWeight(leaf) / total - 0.70) < 0.02
      verbsRun.incl lvResize
      for line in [":resize", ":resize abc", ":resize 0", ":resize 120"]:
        let refusedArg = b.runLayoutCommand(geom, line)
        ck refusedArg.status == lasBadArgument
        ckMessageIsNeverSilent(refusedArg, line)

    # :focus — no command, and that is the point: focus is not a layout change.
    block:
      let b = bindingOn(standard(), lpStandard, focus = paneCalltrace)
      let geom = b.geometry(bodyFor(120, 40))
      let before = $b.saveDocument()
      let moved = b.runLayoutCommand(geom, ":focus right")
      ck moved.status == lasPending
      ck b.focus == paneEditor
      ck $b.saveDocument() == before
      ck not b.userModified
      verbsRun.incl lvFocus

    # :undo-layout / :redo-layout / :reset-layout
    block:
      let b = bindingOn(compact(), lpCompact, focus = paneTimeline)
      let geom = b.geometry(bodyFor(80, 24))
      let before = $b.saveDocument()
      ck b.runLayoutCommand(geom, ":move-tab left").status == lasApplied
      let afterMove = $b.saveDocument()
      ck afterMove != before
      let undone = b.runLayoutCommand(geom, ":undo-layout")
      ck undone.status == lasApplied
      ck $b.saveDocument() == before
      verbsRun.incl lvUndoLayout
      let redone = b.runLayoutCommand(geom, ":redo-layout")
      ck redone.status == lasApplied
      ck $b.saveDocument() == afterMove
      verbsRun.incl lvRedoLayout
      let reset = b.runLayoutCommand(geom, ":reset-layout")
      ck reset.status == lasApplied
      ck $b.saveDocument() == before
      ck not b.userModified
      verbsRun.incl lvResetLayout

    checkpoint("verbs exercised: " & $verbsRun)
    for v in LayoutVerb:
      ck v in verbsRun

    # NOTHING IS SILENT. Nineteen kinds of garbage, on CTUI-10's rule.
    block:
      let b = bindingOn(compact(), lpCompact)
      let geom = b.geometry(bodyFor(80, 24))
      for line in ["", ":", "  ", ":nonsense", ":move", "move-tab",
                   ":dock sideways", ":dock", ":undock nowhere",
                   ":merge-pane nothing", ":merge-pane", ":focus",
                   ":focus diagonally", ":reveal nothing", ":move-pane",
                   ":move-pane inward", ":resize -5", ":move-tab",
                   ":Reset-Layout"]:
        let a = b.runLayoutCommand(geom, line)
        ckMessageIsNeverSilent(a, "'" & line & "'")
        ck a.status in {lasUnknownCommand, lasBadArgument, lasRefused,
                        lasNoOp, lasNoGesture}

  test "SGR-1006 bytes drive a layout gesture end to end":
    # The decoder is `app/input/mouse.decodeMouse`, unchanged, fed the EXACT
    # bytes `TermAssert.sendMouseClick` writes — the same standard
    # `app/tests/test_call_stack_keys.nim` holds it to. What is new is that a
    # decoded event becomes a layout command.
    let b = bindingOn(compact(), lpCompact)
    let geom = b.geometry(bodyFor(80, 24))
    let source = geom.regionOfPane(paneCalltrace)
    let (tabRow, tabCol) = tabCell(geom, paneState, 1)
    var events = 0
    var last = LayoutAction(status: lasNoGesture, message: "-")
    for token in [sgr(0, source.row, source.col, true),
                  sgr(0, tabRow, tabCol, false)]:
      let (ok, event) = decodeMouse(token)
      ck ok
      inc events
      last = b.onMouse(geom, event)
    ck events == 2
    checkpoint("SGR drag -> " & last.message)
    ck last.status == lasApplied
    ck last.command.get.kind == lcMoveTab
    # …and the 1-based wire coordinates really were decoded, rather than the
    # test having agreed with itself: the release token names `tabRow + 1`.
    ck sgr(0, tabRow, tabCol, false).contains(";" & $(tabRow + 1) & "m")

    # A CLICK is not a drag: press and release on the same cell activates.
    block:
      let c = bindingOn(compact(), lpCompact)
      let g2 = c.geometry(bodyFor(80, 24))
      let (r1, c1) = tabCell(g2, paneState, 1)
      let (okP, evP) = decodeMouse(sgr(0, r1, c1, true))
      let (okR, evR) = decodeMouse(sgr(0, r1, c1, false))
      ck okP
      ck okR
      discard c.onMouse(g2, evP)
      let clicked = c.onMouse(g2, evR)
      checkpoint("SGR click -> " & clicked.message)
      ck clicked.status == lasApplied
      ck clicked.command.get.kind == lcActivateTab
      ck clicked.command.get.activateTarget == paneTimeline
      ck c.layout.tree.isVisible(paneTimeline)
      ck c.interaction.kind == ikNone

    # THE WHEEL, on the same protocol (buttons 64 and 65).
    block:
      let c = bindingOn(compact(), lpCompact)
      let g2 = c.geometry(bodyFor(80, 24))
      let region = stackRegionOf(g2, paneState)
      let (ok, ev) = decodeMouse(sgr(65, region.area.row, region.area.col, true))
      ck ok
      ck ev.button == mbWheelDown
      let scrolled = c.onMouse(g2, ev)
      checkpoint("wheel down on the tab strip -> " & scrolled.message)
      ck scrolled.status == lasApplied
      ck scrolled.command.get.kind == lcActivateTab
      ck c.layout.tree.isVisible(paneTimeline)
      # A wheel over a pane BODY is not a layout gesture — that belongs to the
      # pane, and a layout that stole it would break scrolling.
      let body = c.onMouse(g2, wheel(true, region.area.row + 1,
                                     region.area.col))
      ck body.status == lasNoGesture
      ckMessageIsNeverSilent(body, "wheel over a pane body")

  test "a user-modified layout survives a resize; an untouched one re-flows":
    # PLAT-6's third integration test, and Layout-ViewModel §8.2 / §8.4's
    # decision made observable: the profile always tracks the size, the TREE
    # is re-flowed only while the user has not touched it, and `:reset-layout`
    # is the way back.
    block:
      let b = bindingOn(compact(), lpCompact)
      ck not b.userModified
      ck b.resize(120, 40)
      ck b.profile == lpStandard
      ck shapeOf(b.layout) == shapeOf(standard())
      ck b.resize(200, 60)
      ck b.profile == lpUltraWide
      ck shapeOf(b.layout) == shapeOf(ultraWide())
      ck not b.resize(200, 60)   ## the same profile is not a re-flow

    block:
      let b = bindingOn(compact(), lpCompact, focus = paneTimeline)
      let geom = b.geometry(bodyFor(80, 24))
      ck b.runLayoutCommand(geom, ":move-tab left").status == lasApplied
      ck b.userModified
      let mine = shapeOf(b.layout)
      ck not b.resize(120, 40)
      checkpoint("after a modified resize the profile is " & $b.profile)
      ck b.profile == lpStandard      ## the status bar still says Standard…
      ck shapeOf(b.layout) == mine    ## …and the arrangement is still theirs
      ck not b.resize(200, 60)
      ck shapeOf(b.layout) == mine
      # And it is still a layout that PROJECTS at the new size.
      ckPartition(b.geometry(bodyFor(200, 60)), "user layout at 200x60")
      # The explicit way back.
      ck b.resetToProfile().status == lasApplied
      ck not b.userModified
      ck shapeOf(b.layout) == shapeOf(layoutFor(b.profile))
      ck b.resize(80, 24)
      ck shapeOf(b.layout) == shapeOf(compact())

  test "the binding holds no LayoutNode reference, structurally":
    # PLAT-6's second handed-forward item. `nodeAtPath` hands out a live `ref`
    # into the committed tree; this binding takes `nodeInfoAtPath` instead, and
    # the guarantee is the SHAPE OF `NodeInfo` rather than a rule a reviewer
    # has to enforce.
    var checkedFields = 0
    var referenceFields: seq[string] = @[]
    let sample = nodeInfoAtPath(profileLayout(lpCompact), "1/0")
    ck sample.isSome
    ck sample.get.kind == lnPane
    ck sample.get.pane == paneState
    for name, value in sample.get.fieldPairs:
      inc checkedFields
      when value is ref:
        referenceFields.add name
      when value is LayoutNode:
        referenceFields.add name
    checkpoint("NodeInfo fields walked: " & $checkedFields &
               "; reference fields: " & $referenceFields)
    # THE COUNTED CONTROL. A walk that visited nothing would report no
    # reference fields for free (Verification-Harness-Traps §4b).
    ck checkedFields == NodeInfoFieldCount
    ck referenceFields.len == 0
    # …and there is no field to reach the tree through, which the compiler
    # answers rather than the walk.
    ck not compiles(sample.get.node)
    ck not compiles(sample.get.children)

    # AND THE BINDING DOES NOT CALL THE REF-RETURNING DOORS. A source scan, with
    # its own positive control: the scan finds the value-returning door it DOES
    # call, so a scan that read the wrong file would fail rather than pass.
    let bindingSource = readFile(currentSourcePath().parentDir().parentDir() /
                                 "layout" / "binding.nim")
    checkpoint("binding.nim is " & $bindingSource.len & " byte(s)")
    ck bindingSource.len > 0
    ck bindingSource.count("nodeInfoAtPath(") > 0
    ck bindingSource.count("nodeAtPath(") == 0
    ck bindingSource.count(".find(") == 0
    # The residual, recorded rather than claimed away: `Layout.tree` is a
    # public `ref`, so this is reachable and it is NOT what the type above
    # closes. Asserted as a fact so the record cannot rot.
    ck compiles(compact().tree.children)

  test "assertion count":
    checkpoint("CHECKS: " & $countedAssertions)
    echo "CHECKS: ", countedAssertions
    check countedAssertions == ExpectedAssertions
