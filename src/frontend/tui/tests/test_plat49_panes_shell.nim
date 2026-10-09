## test_plat49_panes_shell.nim — PLAT-49 part B, Tier 1: the terminal's panes
## and session tabs as values — the layout binding's GoldenLayout drop zones,
## the footer's auto-hide labels on the status row and a docked pane docked
## open, the call trace's semantic rows, the event log's columns and the top
## bar's session tabs — asserted on the production binding, shell painter,
## pane painters and top bar, over the shared default arrangement. The
## real-PTY twin is `real_terminal/test_plat49_panes.nim`.
##
##   7. SESSION TABS — each tab its own ground with a bar cell between two,
##      the active one `srTabActive`, the others `srSessionTab`; the close
##      control while there are several; the agent's indicator and progress;
##      a hovered tab's tooltip under it.
##   8. CALL TRACE — every row drawn from its `CallRow` parts, each part in
##      its role (arguments `srCallArgs`, return `srCallReturn`); the current
##      call bold on the active-row ground; a press on a row is a jump, on its
##      toggle an expand or collapse.
##   9. FOOTER — the bottom labels are ON THE STATUS ROW, left of the status
##      text, and the body keeps its rows; a click on a label docks its pane
##      OPEN in a band the tree gives up, a second click closes it.
##  11. DROP ZONES — over a pane's body the hit-test answers GoldenLayout's
##      quarters (left and right a quarter of the width, full height; top and
##      bottom a quarter of the height between them; the centre joins),
##      swept cell by cell against the rule restated here; a tab's left half
##      inserts before it, its right half after it; a lone pane's strip joins.
##  14. EVENT LOG — a header row of the visible columns' titles in the
##      model's order; location hidden by default; showing it adds it.
##
## The review (2026-10-03) adds: the status row in the DESKTOP'S ORDER — the
## file info (`headless_app/footer_info`) first, the labels after it, the
## status text after them, and the labels' hit-test where they are drawn;
## the strip's "+" (`tpTabAdd`), its "New tab" tooltip, and — through the
## runtime — the omnibar it opens on `:open `, whose chosen recording goes to
## the host's opener.
##
## The stand-ins, and why none is a mock of anything asserted: the event log
## pane's one seam (`EventPages`) answers from a fixed list of rows — the
## stand-in `event_log.nim` declares for every caller; the session tabs'
## `HeadlessApp` sessions run over `MockBackendService` (a transport that
## answers the DAP handshake; nothing here asserts on what it sends), as
## `test_plat48_top_bar.nim`'s do; and the "+"'s host opener is a CAPTURING
## CLOSURE (`TuiApp.recordingOpener`, the seam the real host fills with
## `openTuiSession`) — the one stand-in, and not a mock: it records the path
## the runtime hands it and answers "" (opened), so what is asserted is the
## runtime's routing, which is all this layer owns; spawning the engine is the
## host's and is exercised on a real PTY (`real_terminal/test_plat49_panes`).

import std/[options, sets, strutils, unicode, unittest]

import isonim_tui

import headless_app/headless_app
import headless_app/layout_interaction
import headless_app/layout_model
import headless_app/session_tabs
import codetracer_embed

import ../app/input/mouse
import ../app/layout/binding
import ../app/layout/profile
import ../app/layout/project
import ../app/layout/tab_strip
import ../app/views/call_trace
import ../app/views/event_log
import ../app/views/shell
import ../app/views/top_bar
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 206
  ## PLAT-51: +3, measured — the call trace's rows end in their scrollbar
  ## scrubber's cell, one more span per row the selected-row sweeps visit,
  ## and the scrubber cell's own role check.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc press(row, col: int): mouse.MouseEvent =
  mouse.MouseEvent(kind: mekPress, button: mbLeft, row: row, col: col)

proc release(row, col: int): mouse.MouseEvent =
  mouse.MouseEvent(kind: mekRelease, button: mbLeft, row: row, col: col)

proc motion(row, col: int): mouse.MouseEvent =
  mouse.MouseEvent(kind: mekMotion, button: mbLeft, row: row, col: col)

proc sharedBinding(cols, rows: int): (LayoutBinding, LayoutGeometry) =
  let profile = selectProfile(cols, rows)
  let b = newLayoutBinding(profileLayoutValue(profile), profile, paneEditor)
  (b, b.geometry(bodyArea(cols, rows)))

proc roleAt(screen: ShellScreen; row, col: int): CellStyle =
  var at = 0
  for span in screen.styledRows[row]:
    let w = cellWidthOf(span.text)
    if col >= at and col < at + w:
      return span.style
    at += w
  CellStyle()

proc oracleZone(dx, dy, w, h: int): DropZone =
  ## GoldenLayout's body segments, RESTATED here from `Stack.getArea` /
  ## `highlightDropZone` (PLAT-51, Layout-ViewModel §4.2.2): left = x within
  ## the first quarter of the content's width, right = the last quarter, both
  ## over its full height; between them top = the upper half, bottom = the
  ## lower half — except the user's smaller middle (the centred third on both
  ## axes) that JOINS. Judged at the cell's centre; reads nothing the binding
  ## reads. A cell on a boundary (none of GoldenLayout's strict tests) is
  ## skipped by the caller (the hit-test resolves no pointer there).
  let fx = (dx.float + 0.5) / w.float
  let fy = (dy.float + 0.5) / h.float
  if fx < 0.25: dzLeftEdge
  elif fx > 0.75: dzRightEdge
  elif fx > 1.0 / 3.0 and fx < 2.0 / 3.0 and fy > 1.0 / 3.0 and
       fy < 2.0 / 3.0: dzCentre
  elif fy < 0.5: dzTopEdge
  else: dzBottomEdge

proc oracleRootZone(inner, region: CellArea; row, col: int):
    Option[DropZone] =
  ## GoldenLayout's GROUND side areas, RESTATED from `GroundItem
  ## .createSideAreas` (50 px deep inside the layout along each outer edge)
  ## and `LayoutManager.getArea` (the smallest area under the pointer wins,
  ## the ground's first on a tie), a terminal cell standing for the
  ## desktop's 9.63 x 22 px character: 5 columns, 2 rows.
  let dw = min(5, max(1, inner.width div 2))
  let dh = min(2, max(1, inner.height div 2))
  var best = high(float)
  for (zone, c0, r0, w, h) in [
      (dzRootLeft, inner.col, inner.row, dw, inner.height),
      (dzRootRight, inner.col + inner.width - dw, inner.row, dw, inner.height),
      (dzRootTop, inner.col, inner.row, inner.width, dh),
      (dzRootBottom, inner.col, inner.row + inner.height - dh, inner.width, dh)]:
    if col >= c0 and col < c0 + w and row >= r0 and row < r0 + h:
      let surface = w.float * 9.625 * h.float * 22.0
      if surface < best:
        best = surface
        result = some(zone)
  let rival = region.width.float * 9.625 * region.height.float * 22.0
  if result.isSome and best > rival:
    result = none(DropZone)

suite "PLAT-49 part B: GoldenLayout's drop zones":

  test "the hit-test answers GoldenLayout's quarters, cell by cell":
    let (b, geom) = sharedBinding(200, 50)
    var swept = 0
    var seen: HashSet[DropZone]
    var wrong: seq[string] = @[]
    for region in geom.projection.regions:
      let path = geom.pathOfPane(region.pane)
      if path.isNone:
        continue
      # GoldenLayout's content area: the pane's box (its divider column is a
      # splitter, in no stack's area) below its strip.
      let below = geom.dropAreaOfPath(path.get)
      let box = boxOfRegion(geom, region.area)
      let a = CellArea(col: below.col, row: below.row, width: box.width,
                       height: below.height)
      if a.width < 8 or a.height < 8:
        continue
      for row in a.row ..< a.row + a.height:
        for col in a.col ..< a.col + a.width:
          # A divider cell belongs to the pane but is not its body.
          let p = pointerAt(b.layout, geom, row, col)
          if p.isNone: continue
          let root = oracleRootZone(geom.inner, region.area, row, col)
          let want =
            if root.isSome: root.get
            else: oracleZone(col - a.col, row - a.row, a.width, a.height)
          inc swept
          seen.incl p.get.zone
          if p.get.zone != want and wrong.len < 8:
            wrong.add $region.pane & " (" & $row & "," & $col & ") " &
                      $p.get.zone & " not " & $want
    for w in wrong: checkpoint(w)
    ck wrong.len == 0
    ck swept > 1000
    # The segments, the smaller centre, and — along the layout's outer edges
    # — the root split.
    ck seen == toHashSet([dzLeftEdge, dzRightEdge, dzTopEdge, dzBottomEdge,
                          dzCentre, dzRootLeft, dzRootRight, dzRootTop,
                          dzRootBottom])
    # PLAT-51: the middle is a third on each axis — a ninth of a body, where
    # PLAT-49's was a quarter of it.
    ck NativeCentreShare > 0.3 and NativeCentreShare < 0.34

  test "the centre joins the stack, an edge splits on its side":
    # Inside the quarters but clear of the layout's ground bands (the state
    # stack meets the layout's top edge, where the band splits the root —
    # the next test).
    for (fx, fy, wantKind, side) in [(0.5, 0.5, lcMoveTab, ssAfter),
                                     (0.05, 0.5, lcSplit, ssBefore),
                                     (0.95, 0.5, lcSplit, ssAfter),
                                     (0.5, 0.2, lcSplit, ssBefore),
                                     (0.5, 0.95, lcSplit, ssAfter)]:
      let (b, first) = sharedBinding(200, 50)
      let src = first.regionOfPane(paneCalltrace)
      discard b.onMouse(first, press(src.row, src.col + 2))
      discard b.onMouse(first, motion(src.row + 2, src.col + 8))
      ck b.interaction.kind == ikDraggingTab
      # PLAT-51: aimed in the frame the drag draws (the call stack lifted out).
      let geom = b.geometry(bodyArea(200, 50))
      let target = geom.dropAreaOfPath(geom.pathOfPane(paneState).get)
      let row = target.row + int(fy * target.height.float)
      let col = target.col + int(fx * target.width.float)
      discard b.onMouse(geom, motion(row, col))
      let dropped = b.onMouse(geom, release(row, col))
      checkpoint($fx & "," & $fy & " -> " & dropped.message)
      ck dropped.status == lasApplied
      ck dropped.command.isSome and dropped.command.get.kind == wantKind
      if wantKind == lcSplit:
        ck dropped.command.get.splitSide == side
        ck dropped.command.get.splitTarget == paneState
        ck not dropped.command.get.splitRoot

  test "along the layout's outer edge a drop splits the WHOLE layout":
    # GoldenLayout's ground side areas (`GroundItem.onDrop`): the band along
    # the layout's own edge, inside it, splits the root on that side — over
    # a stack's body it wins (the stack is the larger area); over the
    # stack's header the header wins (the smaller).
    for (edge, wantAxis, wantSide) in [(leTop, saColumn, ssBefore),
                                       (leRight, saRow, ssAfter),
                                       (leLeft, saRow, ssBefore),
                                       (leBottom, saColumn, ssAfter)]:
      let (b, first) = sharedBinding(200, 50)
      let srcFirst = first.regionOfPane(paneCalltrace)
      discard b.onMouse(first, press(srcFirst.row, srcFirst.col + 2))
      discard b.onMouse(first, motion(srcFirst.row + 2, srcFirst.col + 8))
      # PLAT-51: the frame the drag draws.
      let geom = b.geometry(bodyArea(200, 50))
      let band = geom.rootBandAreaOf(edge)
      ck not band.isEmptyArea
      ck (if edge in {leLeft, leRight}: band.width == 5 else: band.height == 2)
      # A cell in the band's middle, on no pane's strip row (a header there
      # is the smaller area and keeps its own drop — checked below).
      let col = band.col + band.width div 2
      proc onStrip(r: int): bool =
        for region in geom.projection.regions:
          if region.area.row == r and region.area.contains(r, col):
            return true
      var row = band.row + band.height div 2
      if edge in {leLeft, leRight}:
        row = geom.inner.row + geom.inner.height div 2
        while onStrip(row): inc row
      elif onStrip(row):
        row += (if edge == leBottom: -1 else: 1)
      ck not onStrip(row) and band.contains(row, col)
      checkpoint($edge & " (" & $row & "," & $col & ") -> " &
                 $pointerAt(b.layout, geom, row, col))
      discard b.onMouse(geom, motion(row, col))
      ck b.interaction.kind == ikDraggingTab
      let ind = dropIndicationOf(b.interaction)
      ck ind.kind == diRootBand and ind.side == edge
      # The tint is the band itself.
      ck geom.dropIndicationCells(ind).tint == band
      let dropped = b.onMouse(geom, release(row, col))
      checkpoint($edge & " -> " & dropped.message)
      ck dropped.status == lasApplied
      ck dropped.command.isSome and dropped.command.get.kind == lcSplit and
         dropped.command.get.splitRoot and
         dropped.command.get.splitAxis == wantAxis and
         dropped.command.get.splitSide == wantSide and
         dropped.command.get.splitNewPane == paneCalltrace
    # The header beats the band along the top: the state stack's strip row
    # is inside the top band, and a drop there is a tab insertion.
    let (b, geom) = sharedBinding(200, 50)
    let st = geom.regionOfPane(paneState)
    ck geom.rootBandAreaOf(leTop).contains(st.row, st.col + 2)
    ck pointerAt(b.layout, geom, st.row, st.col + 2).get.zone == dzTabStrip

  test "a tab's halves insert before and after it; a click is still that tab's":
    let (b, geom) = sharedBinding(200, 50)
    var stateRegion: PaneRegion
    for r in geom.projection.regions:
      if r.pane == paneState: stateRegion = r
    ck stateRegion.tabs.len >= 2
    let spans = tabSpans(stateRegion.tabs, stateRegion.activeTab)
    let row = stateRegion.area.row
    let stackPath = parentPath(geom.pathOfPane(paneState).get).get
    let leftOf0 = pointerAt(b.layout, geom, row,
                            stateRegion.area.col + spans[0].startCol)
    ck leftOf0.get.zone == dzTabStrip
    ck leftOf0.get.path == childPathOf(stackPath, 0)
    let rightOf0 = pointerAt(b.layout, geom, row, stateRegion.area.col +
                             spans[0].startCol + spans[0].width - 1)
    ck rightOf0.get.zone == dzTabStrip
    ck rightOf0.get.path == childPathOf(stackPath, 1)
    let rightOfLast = pointerAt(b.layout, geom, row, stateRegion.area.col +
                                spans[^1].startCol + spans[^1].width - 1)
    ck rightOfLast.get.zone == dzCentre
    # A CLICK on the right half is still a click on THAT tab: the second
    # tab activated by its right half, then the FIRST by its right half
    # (where a drop would insert after it) — each activates its own tab.
    discard b.onMouse(geom, press(row, stateRegion.area.col +
                                       spans[1].startCol + spans[1].width - 1))
    let clicked = b.onMouse(geom, release(row, stateRegion.area.col +
                                spans[1].startCol + spans[1].width - 1))
    ck clicked.status == lasApplied
    ck clicked.command.get.activateTarget != paneState
    let back = geometryOf(b.layout, geom.body)
    let firstSpans = tabSpans(stateRegion.tabs, 1)
    discard b.onMouse(back, press(row, stateRegion.area.col +
                                       firstSpans[0].startCol +
                                       firstSpans[0].width - 1))
    let clickedFirst = b.onMouse(back, release(row, stateRegion.area.col +
                                firstSpans[0].startCol + firstSpans[0].width - 1))
    ck clickedFirst.status == lasApplied
    ck clickedFirst.command.get.activateTarget == paneState

  test "a lone pane's strip is its header: a drop there joins it":
    let (b, geom) = sharedBinding(200, 50)
    let ed = geom.regionOfPane(paneEditor)
    let p = pointerAt(b.layout, geom, ed.row, ed.col + 10)
    ck p.isSome and p.get.zone == dzCentre
    ck geom.dropAreaOfPath(geom.pathOfPane(paneEditor).get).row == ed.row + 1

suite "PLAT-49 part B: the footer's auto-hide labels are on the status row":

  test "on the status row, left of the status text; the body keeps its rows":
    let (b, geom) = sharedBinding(200, 50)
    var bottom = -1
    for i, s in geom.strips:
      if s.edge == leBottom: bottom = i
    ck bottom >= 0
    ck geom.strips[bottom].area.row == 49
    ck geom.strips[bottom].area.col == 0
    ck geom.inner.row + geom.inner.height == 49
    var model = newShellModel(200, 50)
    model.docked = b.layout.docked
    let screen = shellScreen(model, 200, 50)
    ck screen.rows[49].startsWith(" BUILD ")
    let labelsEnd = geom.strips[bottom].area.col + geom.strips[bottom].area.width
    ck screen.rows[49].find("NORMAL") > labelsEnd
    ck screen.roleAt(49, 2).role == srTabInactive
    ck not screen.rows[48].contains("BUILD")

  test "a click on a label docks its pane open in a band; a second closes it":
    let (b, geom) = sharedBinding(200, 50)
    var slotArea: CellArea
    for s in geom.strips:
      for sl in s.slots:
        if sl.pane == paneBuildOutput: slotArea = sl.area
    let (r, c) = (slotArea.row, slotArea.col + 1)
    discard b.onMouse(geom, press(r, c))
    let opened = b.onMouse(geom, release(r, c))
    ck opened.status == lasApplied
    ck opened.command.get.autoHideDirection == ahOpen
    ck b.interaction.kind == ikNone           # no overlay
    let g2 = b.geometry(bodyArea(200, 50))
    ck not g2.openDock.isEmptyArea
    ck g2.openDockPane == paneBuildOutput
    ck g2.openDock.row + g2.openDock.height == 49
    ck g2.inner.row + g2.inner.height == g2.openDock.row
    # The tree tiles what is left: no region overlaps the band.
    for region in g2.projection.regions:
      ck region.area.row + region.area.height <= g2.openDock.row
    var model = newShellModel(200, 50)
    model.docked = b.layout.docked
    model.layout = b.layout.tree
    let screen = shellScreen(model, 200, 50)
    ck screen.geometry.openDockPane == paneBuildOutput
    ck screen.roleAt(g2.openDock.row, g2.openDock.col + 1).role == srTabActive
    ck screen.roleAt(49, slotArea.col + 1).role == srTabActive
    # The second click on its label closes it.
    discard b.onMouse(g2, press(r, c))
    let closed = b.onMouse(g2, release(r, c))
    ck closed.command.get.autoHideDirection == ahClose
    ck b.geometry(bodyArea(200, 50)).openDock.isEmptyArea

suite "PLAT-49 part B review: the status row in the desktop's order":

  test "the file info, then the labels, then the status text":
    let profile = selectProfile(200, 50)
    let b = newLayoutBinding(profileLayoutValue(profile), profile, paneEditor)
    var model = newShellModel(200, 50)
    model.docked = b.layout.docked
    model.fileInfo = "Python | UTF-8"
    let screen = shellScreen(model, 200, 50)
    let row = screen.rows[49]
    checkpoint(row)
    ck row.startsWith(" Python | UTF-8   BUILD ")
    let lead = footerLeadCells(model.fileInfo)
    ck lead == 1 + "Python | UTF-8".len + 2
    var bottom: DockStrip
    for st in screen.geometry.strips:
      if st.edge == leBottom: bottom = st
    ck bottom.area.col == lead
    ck row.find("BUILD") == bottom.slots[0].area.col + 1
    ck row.find("NORMAL") > bottom.area.col + bottom.area.width
    # The binding's hit-test reads the same lead: a press on BUILD is BUILD.
    b.footerLead = lead
    let g = b.geometry(bodyArea(200, 50))
    ck g.strips.len > 0
    var buildArea: CellArea
    for st in g.strips:
      for sl in st.slots:
        if sl.pane == paneBuildOutput: buildArea = sl.area
    ck buildArea.col == bottom.slots[0].area.col
    let si = g.stripIndexAt(49, buildArea.col + 1)
    ck si >= 0
    let sj = g.strips[si].slotAt(49, buildArea.col + 1)
    ck sj >= 0 and g.strips[si].slots[sj].pane == paneBuildOutput
    # With no file, the labels start the row (nothing to put before them).
    ck footerLeadCells("") == 0

suite "PLAT-49 part B review: the strip's + opens a recording in a new tab":

  test "the + after the tabs — with one session too — and its tooltip":
    var m = TopBarModel(menu: newMenuVM(nativeFrontEndMenu("calc")),
                        omnibar: newOmnibarVM(), hoveredControl: -1,
                        hoveredTab: -1, canAddTab: true)
    let lay = topBarLayout(m, 200)
    let add = lay.segmentOf(tpTabAdd)
    ck add.col > 0 and add.width == NewSessionTabCells
    ck lay.topBarHitAt(add.col + 1).kind == thTabAdd
    var g = newStyledGrid(200, 2)
    paintTopBar(g, m, lay)
    ck g.rowText(0).runeSubStr(add.col, add.width) == " " & NewSessionTabGlyph & " "
    m.hoveredTabAdd = true
    ck m.tooltipText == NewSessionTabTitle
    ck controlTooltipArea(m, lay, 200).col == add.col
    # Without a host that can open one, no "+".
    m.canAddTab = false
    ck topBarLayout(m, 200).segmentOf(tpTabAdd).col < 0

  test "a press on it opens the omnibar on `:open `; the choice goes to the host":
    let app = newTuiApp()
    var asked: seq[string] = @[]
    app.recordingOpener = proc(path: string): string =
      asked.add path
      ""
    app.recordings = @[
      OmnibarEntry(kind: omRecording, label: "calc-1", detail: "/r",
                   target: "/r/calc-1"),
      OmnibarEntry(kind: omRecording, label: "pages-2", detail: "/r",
                   target: "/r/pages-2")]
    let rt = newTuiRuntime(app, resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                      lang = "en_US.UTF-8"), initCapabilityFlags()), 200, 50)
    discard rt.enableLayoutBinding()
    let add = rt.shellScreenOf().topBarLayout.segmentOf(tpTabAdd)
    ck add.col > 0
    discard rt.handleToken("\x1b[<0;" & $(add.col + 2) & ";1M", 0)
    discard rt.handleToken("\x1b[<0;" & $(add.col + 2) & ";1m", 0)
    ck app.omnibar.isOpen and app.omnibar.query == OpenRecordingQuery
    ck app.omnibar.mode == omRecording
    ck app.omnibar.resultLabels == @["calc-1", "pages-2"]
    discard rt.handleToken("\x1b[B", 0)       # Down: pages-2
    discard rt.handleToken("\r", 0)
    ck asked == @["/r/pages-2"]
    ck not app.omnibar.isOpen
    # An opener that refuses says why on the status line.
    app.recordingOpener = proc(path: string): string = "could not open " & path
    discard rt.handleToken("\x1b[<0;" & $(add.col + 2) & ";1M", 0)
    discard rt.handleToken("\x1b[<0;" & $(add.col + 2) & ";1m", 0)
    for ch in "/x/y": discard rt.handleToken($ch, 0)
    discard rt.handleToken("\r", 0)
    ck app.notification == "could not open /x/y"

suite "PLAT-49 part B: the call trace's rows are their semantic parts":

  proc callTraceModel(): CallTraceModel =
    let lines = @[
      CallLine(index: 0, name: "<__main__>", depth: 0, hasChildren: true,
               isExpanded: true, rrTicks: 0),
      CallLine(index: 1, name: "main", depth: 1, hasChildren: true,
               isExpanded: true, rrTicks: 10),
      CallLine(index: 2, name: "evaluate", depth: 2, hasChildren: true,
               isExpanded: false, rrTicks: 20),
      CallLine(index: 3, name: "add", depth: 3, rrTicks: 30)]
    let args = @[@[], @[CallArg(name: ReturnArgName, text: "@[5]")],
                 @[CallArg(name: "expression", text: "\"2 + 3\""),
                   CallArg(name: ReturnArgName, text: "5")],
                 @[CallArg(name: "left", text: "2"),
                   CallArg(name: "right", text: "3")]]
    var rows: seq[CallTraceRow] = @[]
    for i, l in lines:
      rows.add CallTraceRow(index: l.index, name: l.name, depth: l.depth,
                            rrTicks: l.rrTicks, call: callRowOf(l, args[i]))
    initCallTraceModel(rows, tick = 30, stack = @["add", "x", "y", "z"])

  test "each part in its role; the current call selected":
    let m = callTraceModel()
    var g = newStyledGrid(80, 6)
    let area = CellArea(col: 0, row: 0, width: 80, height: 6)
    ck paintCallTrace(g, area, m) == 4
    let text = g.rowText(3)
    ck text.contains("evaluate #2(expression=\"2 + 3\") => 5")
    ck text.startsWith("    " & CallToggleGlyphs[crtCollapsed])
    ck g.rowText(1).startsWith(CallToggleGlyphs[crtExpanded] & " <__main__> #0()")
    ck g.rowText(4).contains("add #3(left=2, right=3)")
    ck g.rowText(4).contains(CallToggleGlyphs[crtLeaf])
    var roles: HashSet[SemanticRole]
    for s in g.rowSpans(3): roles.incl s.style.role
    ck srCallArgs in roles and srCallReturn in roles
    ck srChromeText in roles and srChromeMuted in roles
    # The current call (add, at the stop) is the desktop's selected row:
    # its callee bold (`.call-current`), EVERY part — and the rest of the
    # row to the pane's edge — on the active-row ground (`.event-selected`),
    # its toggle in the body colour (the `active` icon). No other row.
    # (PLAT-51: up to the pane's scrollbar SCRUBBER, which is its last
    # column — the desktop's selected row also ends at its scrollbar.)
    const ScrubberRoles = {srScrubberTrack, srScrubberThumb, srScrubberMark}
    var current = false
    for s in g.rowSpans(4):
      if s.style.bold and s.text.contains("add"): current = true
      if s.text.strip.len > 0 and s.style.role notin ScrubberRoles:
        ck s.style.surface == srSurfaceActiveRow
      if s.text.contains(CallToggleGlyphs[crtLeaf]):
        ck s.style.role == srChromeText
    ck current
    ck g.styleAt(4, 78).surface == srSurfaceActiveRow
    ck g.styleAt(4, 79).role in ScrubberRoles
    for s in g.rowSpans(3):
      ck not s.style.bold
      ck s.style.surface != srSurfaceActiveRow

  test "a press on a row is a jump, on its toggle an expand or collapse":
    let m = callTraceModel()
    let area = CellArea(col: 5, row: 2, width: 80, height: 6)
    let row2 = 2 + 1 + 2                       # call #2 is the third row
    let toggleCol = 5 + 2 * CallRowIndentCells
    let t = m.callTraceHitAt(area, row2, toggleCol)
    ck t.kind == cthToggle and t.index == 2
    let r = m.callTraceHitAt(area, row2, toggleCol + 4)
    ck r.kind == cthRow and r.index == 2
    # A leaf's toggle cell is a row press, the heading row nothing.
    let leaf = m.callTraceHitAt(area, 2 + 1 + 3, 5 + 3 * CallRowIndentCells)
    ck leaf.kind == cthRow and leaf.index == 3
    ck m.callTraceHitAt(area, 2, 10).kind == cthNone
    ck m.callTraceHitAt(area, 2 + 1 + 5, 10).kind == cthNone

suite "PLAT-49 part B: the event log's columns":

  proc logModel(): EventLogModel =
    let rows = @[EventRow(index: 0, tick: 38, file: "/x/main.py", line: 111,
                          content: "2 + 3 = 5\n", category: ecOutput),
                 EventRow(index: 1, tick: 68, file: "/x/main.py", line: 111,
                          content: "10 - 4 + 1 = 7\n", category: ecOutput)]
    result = initEventLogModel(
      pages = proc(offset, limit: int): EventPage =
        EventPage(rows: (if offset == 0: rows else: @[]), atEnd: true))
    result.ensureWindow(0, 16)

  test "a header of the visible columns, location hidden by default":
    let m = logModel()
    let screen = eventLogScreen(m, 80, 6)
    var g = newStyledGrid(80, 6)
    discard paintEventLog(g, CellArea(col: 0, row: 0, width: 80, height: 6), m)
    ck screen.headerRow == 1
    let header = g.rowText(1)
    ck header.contains("tick") and header.contains("#") and
       header.contains("kind") and header.contains("output")
    ck header.find("tick") < header.find("#")
    ck header.find("#") < header.find("kind")
    ck header.find("kind") < header.find("output")
    ck not header.contains("location")
    ck not g.rowText(2).contains("main.py")
    ck g.rowText(2).contains("2 + 3 = 5")
    ck screen.contentColumn == header.find("output")
    ck screen.columnCells.len == 4

  test "showing location adds it; moving output puts it first":
    var m = logModel()
    ck m.columns.showColumn(elcLocation)
    var g = newStyledGrid(80, 6)
    let s = paintEventLog(g, CellArea(col: 0, row: 0, width: 80, height: 6), m)
    ck g.rowText(1).contains("location")
    ck g.rowText(2).contains("main.py:111")
    ck s.columnCells.len == 5
    ck m.columns.moveColumn(elcOutput, -4)
    var g2 = newStyledGrid(80, 6)
    let s2 = paintEventLog(g2, CellArea(col: 0, row: 0, width: 80, height: 6), m)
    ck s2.columnCells[0][0] == elcOutput
    ck g2.rowText(2).startsWith("2 + 3 = 5")
    ck s2.contentColumn == 0

  test "the omnibar's column commands change the pane's columns":
    let rt = newTuiRuntime(newTuiApp(), resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                      lang = "en_US.UTF-8"), initCapabilityFlags()), 200, 50)
    var outcome: RuntimeOutcome
    ck not rt.app.eventLog.columns.isVisible(elcLocation)
    rt.runMenuAction(EventLogColumnCommandPrefix & "toggle:location", outcome)
    ck rt.app.eventLog.columns.isVisible(elcLocation)
    ck rt.app.notification.contains("event log columns")
    rt.runMenuAction(EventLogColumnCommandPrefix & "left:output", outcome)
    ck rt.app.eventLog.columns.visibleColumns ==
       @[elcTick, elcIndex, elcLocation, elcOutput, elcKind]
    rt.runMenuAction(EventLogColumnCommandPrefix & "toggle:location", outcome)
    ck not rt.app.eventLog.columns.isVisible(elcLocation)

suite "PLAT-49 part B: session tabs are separate items with the spec's state":

  proc tabsModel(): TopBarModel =
    let agent = SessionTabAgent(present: true, running: true,
                                lifecycle: aslRunning, task: "Fix parser",
                                completed: 2, total: 5)
    TopBarModel(menu: newMenuVM(nativeFrontEndMenu("calc")),
                omnibar: newOmnibarVM(), hoveredControl: -1, hoveredTab: -1,
                tabs: @[
      SessionTabView(id: HeadlessSessionId(0), title: "calc", active: true,
                     label: "calc", tooltip: "calc", closable: true),
      SessionTabView(id: HeadlessSessionId(1), title: "agent", active: false,
                     label: tabLabelOf("agent", agent),
                     tooltip: agentTooltipText("agent", agent),
                     closable: true, agent: agent),
      SessionTabView(id: HeadlessSessionId(2), title: "other", active: false,
                     label: "other", tooltip: "other", closable: true)])

  test "each tab its own ground, a bar cell between two, the close control":
    let m = tabsModel()
    let lay = topBarLayout(m, 240)
    var g = newStyledGrid(240, 1)
    paintTopBar(g, m, lay)
    let t0 = lay.segmentOf(tpTab, 0)
    let t1 = lay.segmentOf(tpTab, 1)
    let t2 = lay.segmentOf(tpTab, 2)
    ck t0.col >= 0 and t1.col >= 0 and t2.col >= 0
    ck t1.col == t0.col + t0.width + SessionTabGapCells
    ck t2.col == t1.col + t1.width + SessionTabGapCells
    proc surfaceAt(col: int): SemanticRole =
      var at = 0
      for s in g.rowSpans(0):
        let w = cellWidthOf(s.text)
        if col >= at and col < at + w: return s.style.surface
        at += w
      srNone
    ck surfaceAt(t0.col + 1) == srTabActive
    ck surfaceAt(t1.col + 1) == srSessionTab
    ck surfaceAt(t2.col + 1) == srSessionTab
    ck surfaceAt(t0.col + t0.width) notin {srTabActive, srSessionTab}
    let row = g.rowText(0)
    ck row.runeSubStr(t1.col, t1.width).contains("⟳ agent 2/5")
    ck row.runeSubStr(t1.col, t1.width).contains(SessionTabCloseGlyph)
    ck lay.topBarHitAt(t1.col + t1.width - 2, m.tabs).kind == thTabClose
    ck lay.topBarHitAt(t1.col + 2, m.tabs).kind == thTab
    # One session: no tabs at all, as the desktop hides a lone tab.
    var one = m
    one.tabs = @[m.tabs[0]]
    ck topBarLayout(one, 240).segmentOf(tpTab, 0).col < 0

  test "a hovered tab's tooltip — the agent's task and progress — under it":
    var m = tabsModel()
    m.hoveredTab = 1
    let lay = topBarLayout(m, 240)
    let a = controlTooltipArea(m, lay, 240)
    ck a.row == 1 and a.col == lay.segmentOf(tpTab, 1).col
    var g = newStyledGrid(240, 2)
    paintControlTooltip(g, m, lay, 240)
    ck g.rowText(1).contains("agent — agent working: Fix parser — 2/5 milestones (40%)")

  test "the tabs of a real application: label, close, agent from its store":
    let app = newHeadlessApp()
    discard app.openSession(newMockBackendService(autoRespond = true).toBackendService(),
                            title = "calc")
    let second = app.openSession(newMockBackendService(autoRespond = true).toBackendService(),
                                 title = "fix")
    second.session.store.agentSessions.val = AgentSessionsState(
      activeTabId: "a", sessions: @[AgentServiceSessionEntry(
        tabId: "a", title: "Fix it", lifecycle: aslRunning,
        milestonesCompleted: 1, milestonesTotal: 4)])
    let tabs = app.tabsOf()
    ck tabs.len == 2
    ck tabs[0].closable and tabs[1].closable
    ck not tabs[0].agent.present
    ck tabs[1].agent.running
    ck tabs[1].label == "fix 1/4"
    ck tabs[1].tooltip.contains("Fix it — 1/4 milestones (25%)")
    ck app.closeTab(0)
    ck not app.tabsOf()[0].closable

suite "PLAT-49 part B shell: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
