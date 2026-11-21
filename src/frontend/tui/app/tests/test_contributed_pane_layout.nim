## test_contributed_pane_layout.nim — the terminal docks contributed
## (extension) panes: the projection gives them their own region list, the fit
## rules hold them to their own minimum, the layout verbs and the mouse act on
## them, a plugin's pane is placed beside a core pane without taking the tab,
## and the shell paints a pane from an extension that is not loaded as a
## sentence naming it (Extensibility-Model.md §6, §10 decision 2).
##
## No mocks and no stand-ins: the projection, the binding and the shell are
## the shipped modules over real layout values; the plugin pane's rows are a
## `ContributedPaneView` value, which is exactly what the runtime hands the
## shell from `PluginsService.paneView`.

import std/[options, strutils, tables, unicode, unittest]

import headless_app/layout_interaction
import headless_app/layout_model

import ../input/mouse
import ../layout/binding
import ../layout/cells
import ../layout/profile
import ../layout/project
import ../views/shell

const
  Metrics = "acme-tools.metrics/overview"
  Flame = "acme-tools.flame/flame"

template ck(cond: untyped) = check cond

proc arrangement(): Layout =
  ## Source beside a stack (Variables | Metrics), Flame below them.
  initLayout(row([
    pane(paneEditor, weight = 2.0),
    column([
      stack([pane(paneState), contributedPaneNode(Metrics, "Metrics")],
            activeIndex = 1),
      contributedPaneNode(Flame, "Flame")])]))

suite "the projection gives a contributed leaf its own region":

  test "no built-in region is a contributed pane, and the two lists partition the area":
    let area = bodyArea(160, 40)
    let p = projectLayout(arrangement().tree, area)
    ck p.status == prOk
    var builtins: seq[PaneKind] = @[]
    for r in p.regions: builtins.add r.pane
    # THE TRAP: a contributed leaf's `pane` is `paneEditor`. Exactly ONE
    # editor region — the real one.
    ck builtins == @[paneEditor]
    ck p.contributed.len == 2
    ck p.contributed[0].id == Metrics
    ck p.contributed[0].tabs == @["Variables", "Metrics"]
    ck p.contributed[0].activeTab == 1
    ck p.contributed[1].id == Flame
    ck coverageProblems(p).len == 0
    ck coveredCells(p) == area.width * area.height
    # The built-in list alone does NOT cover the area: the contributed cells
    # are real and are someone's.
    ck coverageProblems(p.regions, area).len > 0
    ck not p.regionForContributed(Flame).isEmptyArea
    ck p.regionFor(paneState).isEmptyArea

  test "an untitled contributed tab is named by its surface":
    let p = projectLayout(row([stack([pane(paneState),
                                      contributedPaneNode(Flame)])]),
                          bodyArea(120, 30))
    ck p.regions[0].tabs == @["Variables", "flame"]

  test "a tree whose only visible pane is contributed is projected, not degraded":
    let p = projectLayout(stack([pane(paneState), contributedPaneNode(Flame)],
                                activeIndex = 1), bodyArea(80, 24))
    ck p.status == prOk
    ck p.regions.len == 0
    ck p.contributed.len == 1

suite "fit and minimum-size rules handle a contributed pane":

  test "a contributed leaf is held to its own minimum, not the editor's":
    let t = row([contributedPaneNode(Flame), pane(paneState)])
    ck minimumWidth(t) == minContributedWidth(Flame) + minPaneWidth(paneState)
    ck minContributedWidth(Flame) < minPaneWidth(paneEditor)
    ck minContributedHeight(Flame) == 2

  test "a contributed region too small for its minimum is reported by id":
    let t = row([pane(paneEditor, weight = 30.0),
                 contributedPaneNode(Flame, weight = 1.0)])
    let problems = fitProblems(t, 80, 24)
    var named = false
    for p in problems:
      if p.startsWith(Flame): named = true
    checkpoint $problems
    ck named

suite "the layout verbs and the mouse act on a contributed pane":

  test "focus, move, dock, unpin, merge and close a contributed pane":
    let b = newLayoutBinding(arrangement(), lpStandard)
    var geom = b.geometry(bodyArea(160, 40))
    b.focusOn(contributedRef(Flame))
    ck b.focusRef.sameSlot(contributedRef(Flame))
    # `:focus up` leaves Flame for the region above it, a CONTRIBUTED one.
    ck b.runLayoutCommand(geom, ":focus up").status == lasPending
    ck b.focusContributed == Metrics
    ck b.runLayoutCommand(geom, ":focus left").status == lasPending
    ck b.focusContributed == ""
    ck b.focus == paneEditor
    # `:move-tab left` reorders Metrics in its stack.
    b.focusOn(contributedRef(Metrics))
    ck b.runLayoutCommand(geom, ":move-tab first").status == lasApplied
    ck b.layout.tree.children[1].children[0].children[0].matches(
      contributedRef(Metrics))
    # `:move-pane left` splits the editor with it.
    geom = b.geometry(bodyArea(160, 40))
    ck b.runLayoutCommand(geom, ":move-pane left").status == lasApplied
    let split = parentOf(b.layout.tree,
                         b.layout.tree.findContributed(Metrics))
    ck split.kind == lnRow
    ck split.children.len == 2
    ck split.children[0].matches(contributedRef(Metrics))
    ck split.children[1].matches(builtinRef(paneEditor))
    # `:dock right` and `:unpin <id>`.
    geom = b.geometry(bodyArea(160, 40))
    ck b.runLayoutCommand(geom, ":dock right").status == lasApplied
    ck b.layout.dockedIndex(contributedRef(Metrics)) >= 0
    geom = b.geometry(bodyArea(160, 40))
    ck geom.strips.len >= 1
    var slotNamed = false
    for s in geom.strips:
      for slot in s.slots:
        if slot.contributed == Metrics and slot.title == "Metrics":
          slotNamed = true
    ck slotNamed
    ck b.runLayoutCommand(geom, ":unpin " & Metrics).status == lasApplied
    ck b.layout.tree.containsContributed(Metrics)
    # `:merge-pane state` from Flame: Flame joins the Variables stack.
    b.focusOn(contributedRef(Flame))
    geom = b.geometry(bodyArea(160, 40))
    ck b.runLayoutCommand(geom, ":merge-pane state").status == lasApplied
    let st = parentOf(b.layout.tree, b.layout.tree.find(paneState))
    ck st.kind == lnStack
    var flameThere = false
    for c in st.children:
      if c.matches(contributedRef(Flame)): flameThere = true
    ck flameThere
    # `:close-pane` and it is not placed again.
    geom = b.geometry(bodyArea(160, 40))
    ck b.runLayoutCommand(geom, ":close-pane " & Flame).status == lasApplied
    ck not b.layout.tree.containsContributed(Flame)
    ck b.placeContributedPane(Flame, "Flame").status == lasNoOp
    ck not b.layout.tree.containsContributed(Flame)

  test "a press focuses a contributed region; a press on its tab selects it":
    let b = newLayoutBinding(arrangement(), lpStandard)
    let geom = b.geometry(bodyArea(160, 40))
    let flame = geom.projection.regionForContributed(Flame)
    let press = MouseEvent(kind: mekPress, button: mbLeft,
                           row: flame.row + 1, col: flame.col + 1)
    discard b.onMouse(geom, press)
    ck b.focusContributed == Flame
    # The Variables tab on Metrics' strip: a BUILT-IN tab on a contributed
    # region's strip selects Variables, never the editor.
    let metrics = geom.projection.regionForContributed(Metrics)
    # A press MARKS the tab and the release (on the same cell: a click)
    # selects it, exactly as for a built-in tab.
    let onTab = MouseEvent(kind: mekPress, button: mbLeft, row: metrics.row,
                           col: metrics.col + 2)
    discard b.onMouse(geom, onTab)
    let acted = b.onMouse(geom, MouseEvent(kind: mekRelease, button: mbLeft,
                                           row: metrics.row,
                                           col: metrics.col + 2))
    checkpoint acted.message
    ck b.layout.tree.isVisible(builtinRef(paneState))
    ck b.focus == paneState
    ck b.focusContributed == ""

  test "a plugin's pane is placed beside a core pane, and the tab shown stays":
    let b = newLayoutBinding(lpStandard)
    ck not b.userModified
    let visibleBefore = b.layout.tree.isVisible(paneState)
    let placed = b.placeContributedPane(Metrics, "Metrics")
    ck placed.status == lasApplied
    ck b.layout.tree.containsContributed(Metrics)
    let leaf = b.layout.tree.findContributed(Metrics)
    let parent = parentOf(b.layout.tree, leaf)
    var besideState = false
    for c in parent.children:
      if c.matches(builtinRef(paneState)): besideState = true
    ck besideState
    ck b.layout.tree.isVisible(paneState) == visibleBefore
    ck not b.userModified
    ck b.placeContributedPane(Metrics, "Metrics").status == lasNoOp

suite "the shell paints a contributed pane":

  test "a loaded pane draws its rows; an unloaded one names its extension":
    var model = newShellModel(160, 40)
    model.layout = arrangement().tree
    model.contributedViews[Flame] = ContributedPaneView(
      lines: @["  main 60%", "> work 40%"], cursor: 1)
    let screen = shellScreen(model, 160, 40)
    let all = screen.rows.join("\n")
    ck "work 40%" in all
    # Metrics has no view: its extension is not loaded, and its slot says so.
    ck "This pane is provided by an" in all
    ck Metrics in all
    var flameRow = -1
    for i, r in screen.rows:
      if "work 40%" in r: flameRow = i
    ck flameRow >= 0
    ck screen.projection.regionForContributed(Flame).contains(flameRow,
      screen.projection.regionForContributed(Flame).col)

  test "a decoration is drawn on its line of the source pane":
    var model = newShellModel(160, 40)
    model.sourceDecorations = @[SourceDecorationMark(line: 3, glyph: "◆",
                                                     text: "metrics: line 3",
                                                     plugin: "acme-tools.metrics")]
    model.source.path = "/tmp/x.py"
    model.source.heldLines = @["a = 1", "b = 2", "c = 3", "d = 4"]
    model.source.firstHeldLine = 1
    model.source.totalLineCount = 4
    model.source.viewportTop = 1
    model.source.executionLine = 3
    let screen = shellScreen(model, 160, 40)
    var decoRow = -1
    var codeRow = -1
    for i, r in screen.rows:
      if "◆ metrics: line 3" in r: decoRow = i
      if "c = 3" in r: codeRow = i
    checkpoint screen.rows.join("\n")
    ck codeRow >= 0
    ck decoRow == codeRow

proc press(row, col: int): MouseEvent =
  MouseEvent(kind: mekPress, button: mbLeft, row: row, col: col)

proc motion(row, col: int): MouseEvent =
  MouseEvent(kind: mekMotion, button: mbLeft, row: row, col: col)

proc release(row, col: int): MouseEvent =
  MouseEvent(kind: mekRelease, button: mbLeft, row: row, col: col)

suite "a plugin pane moves, reveals and marks like a built-in one":

  test "a plugin tab is picked up, dragged and dropped through the gesture machine":
    let b = newLayoutBinding(arrangement(), lpStandard)
    var geom = b.geometry(bodyArea(160, 40))
    let flame = geom.projection.regionForContributed(Flame)
    let editor = geom.projection.regionFor(paneEditor)
    # Press on Flame's lone tab label, move past the threshold onto the
    # editor's body, release: the drop is a real layout command.
    discard b.onMouse(geom, press(flame.row, flame.col + 2))
    ck b.pendingPickRef.isSome
    ck b.pendingPickRef.get.sameSlot(contributedRef(Flame))
    ck b.pendingPick.isNone
    let target = (editor.row + editor.height div 2, editor.col + editor.width div 2)
    discard b.onMouse(geom, motion(target[0], target[1]))
    ck b.interaction.kind == ikDraggingTab
    ck b.interaction.sourceRef.sameSlot(contributedRef(Flame))
    geom = b.geometry(bodyArea(160, 40))
    let dropped = b.onMouse(geom, release(target[0], target[1]))
    checkpoint dropped.message
    ck dropped.status == lasApplied
    ck dropped.command.isSome
    ck dropped.command.get.subjectRef.sameSlot(contributedRef(Flame))
    ck b.interaction.kind == ikNone
    # It moved next to (or into) the editor's region.
    let leaf = b.layout.tree.findContributed(Flame)
    ck not leaf.isNil
    let p = parentOf(b.layout.tree, leaf)
    var withEditor = false
    for c in p.children:
      if c.matches(builtinRef(paneEditor)): withEditor = true
    ck withEditor
    ck b.layout.validate({paneEditor, paneState}).len == 0

  test "a drop beside a plugin pane names the plugin pane, never the editor":
    # The zero-value trap in the drop targets: the stack's first tab is an
    # extension's, and the anchor a drop into it names must be that pane.
    let l = initLayout(row([
      pane(paneEditor),
      stack([contributedPaneNode(Metrics), pane(paneState)], activeIndex = 0)]))
    let path = panePath(l, contributedRef(Metrics))
    ck path.isSome
    let targets = dropTargetsFor(l, builtinRef(paneEditor),
                                 LayoutPointer(path: path.get, zone: dzTabStrip))
    var intoStack = 0
    for t in targets:
      if t.kind == dtIntoStack:
        inc intoStack
        ck t.anchorOf.sameSlot(contributedRef(Metrics))
    ck intoStack > 0
    let splits = dropTargetsFor(l, builtinRef(paneEditor),
                                LayoutPointer(path: path.get, zone: dzLeftEdge))
    for t in splits:
      if t.kind in {dtSplitBefore, dtSplitAfter}:
        ck t.splitOf.sameSlot(contributedRef(Metrics))

  test "a click on a docked plugin pane's label docks it open, and paints it":
    let b = newLayoutBinding(arrangement(), lpStandard)
    b.focusOn(contributedRef(Flame))
    var geom = b.geometry(bodyArea(160, 40))
    ck b.runLayoutCommand(geom, ":dock bottom").status == lasApplied
    geom = b.geometry(bodyArea(160, 40))
    var slot = CellArea()
    for s in geom.strips:
      for sl in s.slots:
        if sl.contributed == Flame: slot = sl.area
    ck not slot.isEmptyArea
    discard b.onMouse(geom, press(slot.row, slot.col + 1))
    let clicked = b.onMouse(geom, release(slot.row, slot.col + 1))
    checkpoint clicked.message
    ck clicked.status == lasApplied
    geom = b.geometry(bodyArea(160, 40))
    ck geom.openDockContributed == Flame
    ck not geom.openDock.isEmptyArea
    var model = newShellModel(160, 40)
    model.layout = b.layout.tree
    model.docked = b.layout.docked
    model.contributedViews[Flame] = ContributedPaneView(
      lines: @["  main 60%", "  work 40%"], cursor: -1)
    let screen = shellScreen(model, 160, 40)
    var shownInBand = false
    for i in geom.openDock.row ..< geom.openDock.row + geom.openDock.height:
      if "work 40%" in screen.rows[i]: shownInBand = true
    ck shownInBand
    # A second click closes it again.
    discard b.onMouse(geom, press(slot.row, slot.col + 1))
    discard b.onMouse(geom, release(slot.row, slot.col + 1))
    ck b.geometry(bodyArea(160, 40)).openDock.isEmptyArea
    # `:reveal <id>` reveals it as an overlay.
    ck b.runLayoutCommand(geom, ":reveal " & Flame).status == lasPending
    ck b.geometry(bodyArea(160, 40)).revealContributed == Flame

  test "a plugin's marker is a glyph in the gutter's mark column":
    var model = newShellModel(160, 40)
    model.sourceMarkers = @[SourceDecorationMark(line: 2, glyph: "★",
                                                 text: "hotspot",
                                                 plugin: "acme-tools.metrics")]
    model.source.path = "/tmp/x.py"
    model.source.heldLines = @["a = 1", "b = 2", "c = 3", "d = 4"]
    model.source.firstHeldLine = 1
    model.source.totalLineCount = 4
    model.source.viewportTop = 1
    model.source.executionLine = 3
    let screen = shellScreen(model, 160, 40)
    let editor = screen.projection.regionFor(paneEditor)
    var marked = -1
    for i, r in screen.rows:
      if "b = 2" in r: marked = i
    ck marked >= 0
    checkpoint screen.rows[marked]
    ck screen.rows[marked].runeAtPos(editor.col) == "★".runeAt(0)
    # Not at the end of the line (that is a decoration's place), and on no
    # other line.
    ck not (" ★ hotspot" in screen.rows[marked])
    for i, r in screen.rows:
      if i != marked and i > editor.row and i < editor.row + editor.height:
        ck r.runeAtPos(editor.col) != "★".runeAt(0)
