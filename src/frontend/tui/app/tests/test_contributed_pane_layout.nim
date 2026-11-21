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

import std/[options, strutils, tables, unittest]

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
    let onTab = MouseEvent(kind: mekPress, button: mbLeft, row: metrics.row,
                           col: metrics.col + 2)
    let acted = b.onMouse(geom, onTab)
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
