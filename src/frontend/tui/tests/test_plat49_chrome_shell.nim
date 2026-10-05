## test_plat49_chrome_shell.nim — PLAT-49 part A, Tier 1: the terminal's
## chrome as values — the layout binding's drag threshold, the shell's panes,
## strips and dividers, the variables rows, the top bar's tooltip and caret —
## asserted on the production binding, the production shell painter and the
## production top bar, over the shared default arrangement. The real-PTY twin
## is `real_terminal/test_plat49_chrome.nim`.
##
##   2. A PRESS PICKS NOTHING UP — it marks a tab (`pendingPick`); a release
##      within the threshold is a click (the tab is activated); motion past
##      `DragThresholdCols` / `DragThresholdRows` begins the drag; a release
##      past it with no motion report is the whole drag at once; a divider
##      released within the threshold resizes nothing.
##   3. NO TITLE ROW — every pane's first row is a tab strip (a lone pane's
##      one tab names it; a lone editor's names its file), no painter's
##      heading (`FILES`, `CALL TRACE`, `VARIABLES`, …) shows.
##   4. TAB STRIPS — the strip on `srTabBar`, the selected tab on
##      `srTabActive` (its own background and foreground), the others on
##      `srTabInactive`.
##   5. TOOLTIP — a hovered control's tooltip is drawn on the row under it.
##   6. OMNIBAR — the closed field shows the ViewModel's placeholder on
##      `srSurfaceField`; open, the caret is where the ViewModel's `cursor` is.
##  12. VARIABLES — no scope rows; each row's first cell is its category tag
##      in the category's role.
##  13. DIVIDERS — every divider cell on the panes' own ground (PLAT-50: the
##      strip's ground in a tab-strip row).
##
## No mocks: the product's own layout binding, shell, top bar and ViewModels;
## the variables pane's one seam (`NodeChildren`) is answered from a fixed
## list of nodes, the stand-in `variables.nim` declares for every caller.

import std/[options, sets, strutils, unicode, unittest]

import isonim_tui

import headless_app/layout_interaction
import headless_app/layout_model
import codetracer_embed

import ../app/input/mouse
import ../app/layout/binding
import ../app/layout/profile
import ../app/layout/project
import ../app/layout/tab_strip
import ../app/views/shell
import ../app/views/top_bar
import ../app/views/tree_node
import ../app/views/variables

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 350

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

proc tabCell(geom: LayoutGeometry; pane: PaneKind; slot: int): (int, int) =
  for r in geom.projection.regions:
    if r.pane == pane:
      let spans = tabSpans(r.tabs, r.activeTab)
      return (r.area.row, r.area.col + spans[slot].startCol +
                          spans[slot].width div 2)
  (-1, -1)

proc showing(b: LayoutBinding; pane: PaneKind): bool =
  ## Whether `pane` is the active tab of its stack on the current layout.
  for r in b.geometry(bodyArea(200, 50)).projection.regions:
    if r.pane == pane:
      return true
  false

suite "PLAT-49: a press marks a tab; only motion past the threshold drags":

  test "a click activates, a small move is still a click, past the threshold is a drag":
    let (b, geom) = sharedBinding(200, 50)
    # The Files stack's second tab (VCS).
    let (row, col) = tabCell(geom, paneFileTree, 1)
    ck row >= 0
    discard b.onMouse(geom, press(row, col))
    ck b.pendingPick == some(paneVcs)
    ck b.interaction.kind == ikNone
    let clicked = b.onMouse(geom, release(row, col))
    ck clicked.status == lasApplied
    ck b.showing(paneVcs)
    # One column of motion and a release one column over, on the Files tab:
    # a click — Files is shown again.
    let g1 = b.geometry(bodyArea(200, 50))
    let (r2, c2) = tabCell(g1, paneVcs, 0)
    discard b.onMouse(g1, press(r2, c2))
    ck b.pendingPick == some(paneFileTree)
    let small = b.onMouse(g1, motion(r2, c2 + 1))
    ck small.status == lasNoGesture
    ck b.interaction.kind == ikNone
    ck not b.dragThresholdPassed(r2, c2 + 1)
    let again = b.onMouse(g1, release(r2, c2 + 1))
    ck again.status == lasApplied
    ck b.interaction.kind == ikNone
    ck b.showing(paneFileTree)
    # Past the threshold, on either axis: the drag begins.
    ck b.dragThresholdPassed(-1, -1) == false
    discard b.onMouse(g1, press(r2, c2))
    ck b.dragThresholdPassed(r2, c2 + DragThresholdCols)
    ck b.dragThresholdPassed(r2 + DragThresholdRows, c2)
    let drag = b.onMouse(g1, motion(r2 + 5, c2 + 20))
    ck drag.status == lasPending
    ck b.interaction.kind == ikDraggingTab
    ck b.interaction.source == paneFileTree
    discard b.cancelGesture()

  test "a release past the threshold with no motion is the whole drag; a plain click says 'click'":
    let (b, geom) = sharedBinding(200, 50)
    let (row, col) = tabCell(geom, paneFileTree, 1)
    discard b.onMouse(geom, press(row, col))
    # Released on the header row: a dock, with no motion report in between.
    let dropped = b.onMouse(geom, release(0, 100))
    ck dropped.status == lasApplied
    ck b.layout.dockedIndex(paneVcs) >= 0
    # A click in a pane body: a focus, nothing picked up, no drag spoken of.
    let geom2 = b.geometry(bodyArea(200, 50))
    let body = geom2.regionOfPane(paneEditor)
    let p = b.onMouse(geom2, press(body.row + 5, body.col + 10))
    ck p.status == lasNoGesture
    ck b.pendingPick.isNone
    let r = b.onMouse(geom2, release(body.row + 5, body.col + 10))
    ck r.status == lasNoGesture
    ck not r.message.contains("drag")

  test "a divider released within the threshold resizes nothing":
    let (b, geom) = sharedBinding(200, 50)
    let ed = geom.regionOfPane(paneEditor)
    let row = ed.row + 5
    let col = ed.col + ed.width - 1         # the editor's right divider
    discard b.onMouse(geom, press(row, col))
    ck b.interaction.kind == ikResizingSplit
    discard b.onMouse(geom, motion(row, col + 1))
    let r = b.onMouse(geom, release(row, col + 1))
    ck r.status == lasNoGesture
    ck b.history.log.len == 0
    discard b.onMouse(geom, press(row, col))
    let moved = b.onMouse(geom, release(row, col + 6))
    ck moved.status == lasApplied
    ck b.history.log.len == 1

suite "PLAT-49: panes, strips and dividers on the shell":

  test "every pane's first row is a strip; no painter heading shows":
    var model = newShellModel(200, 50)
    model.source.path = "/tmp/calc/main.py"
    let screen = shellScreen(model, 200, 50)
    var strips = 0
    for region in screen.projection.regions:
      let a = region.area
      let first = screen.styledRows[a.row]
      var roles: HashSet[SemanticRole]
      var at = 0
      for span in first:
        let w = cellWidthOf(span.text)
        if at + w > a.col and at < a.col + a.width - 1:
          roles.incl span.style.role
        at += w
      checkpoint($region.pane & " first-row roles " & $roles)
      ck srTabActive in roles
      ck roles <= toHashSet([srTabActive, srTabInactive, srTabBar,
                             srBorderPane, srBorderFocused])
      inc strips
    ck strips == screen.projection.regions.len
    for r in 1 ..< 48:                        # the body, above the footer
      let line = screen.rows[r]
      for heading in ["FILES", "CALL TRACE", "VARIABLES", "TRACEPOINTS",
                      "SOURCE ", "BUILD "]:
        ck not line.contains(heading)
    # A lone editor's one tab names its file.
    ck screen.rows[1].contains(" main.py ")

  test "every divider cell sits on the panes' own surface":
    # PLAT-50 refines finding 13: a divider in a BODY row is on the ground of
    # the pane beside it (the panel, or the editor's own); in a TAB-STRIP
    # row it is the strip's ground, so two strips connect (the user,
    # 2026-10-02).
    let model = newShellModel(200, 50)
    let screen = shellScreen(model, 200, 50)
    let cells = dividerCells(screen.projection.regions, screen.geometry.inner)
    let strips = stripCells(screen.projection.regions, screen.geometry.inner)
    ck cells.len > 50
    var onSurface = 0
    for (row, col) in cells:
      let inStrip = (row, col - 1) in strips or (row, col + 1) in strips
      var at = 0
      for span in screen.styledRows[row]:
        let w = cellWidthOf(span.text)
        if col >= at and col < at + w:
          if inStrip and span.style.surface == srTabBar: inc onSurface
          elif not inStrip and span.style.surface in {srSurfacePanel,
                                                       srSurfaceEditor}:
            inc onSurface
          break
        at += w
    ck onSurface == cells.len

suite "PLAT-49: the top bar's tooltip and omnibar":

  test "a hovered control's tooltip is drawn under it":
    var m = TopBarModel(menu: newMenuVM(nativeFrontEndMenu("calc")),
                        omnibar: newOmnibarVM(), hoveredControl:
                          controlIndex("next"),
                        hoverTooltip: transportTooltip("next", "n"))
    let lay = topBarLayout(m, 200)
    let a = controlTooltipArea(m, lay, 200)
    ck a.row == 1 and a.height == 1
    ck a.col == lay.segmentOf(tpControl, controlIndex("next")).col
    var g = newStyledGrid(200, 3)
    paintControlTooltip(g, m, lay, 200)
    ck g.rowText(1).contains(" Next (n) ")
    m.hoveredControl = -1
    ck controlTooltipArea(m, lay, 200).width == 0

  test "the field shows the ViewModel's placeholder; open, the caret is at the ViewModel's cursor":
    let ob = newOmnibarVM()
    var m = TopBarModel(menu: newMenuVM(nativeFrontEndMenu("calc")),
                        omnibar: ob, hoveredControl: -1)
    var lay = topBarLayout(m, 200)
    var g = newStyledGrid(200, 1)
    paintTopBar(g, m, lay)
    let seg = lay.segmentOf(tpOmnibar)
    ck g.rowText(0).contains("⌕ " & OmnibarPlaceholder[0 ..< 12])
    var spans: seq[StyledSpan] = g.rowSpans(0)
    var at = 0
    var fieldSurface = srNone
    for s in spans:
      if at >= seg.col + 1 and fieldSurface == srNone:
        fieldSurface = s.style.surface
      at += cellWidthOf(s.text)
    ck fieldSurface == srSurfaceField
    # …and the BOX is the field's ground end to end, not only under its
    # text: the cell before its right border (padding past the placeholder)
    # too. PLAT-50: the last cell itself is the border — the bar's ground
    # under a ui/border/secondary edge line.
    var lastSurface = srNone
    var edge = srNone
    at = 0
    for s in spans:
      let w = cellWidthOf(s.text)
      if seg.col + seg.width - 2 >= at and seg.col + seg.width - 2 < at + w:
        lastSurface = s.style.surface
      if seg.col + seg.width - 1 >= at and seg.col + seg.width - 1 < at + w:
        edge = s.style.surface
      at += w
    ck lastSurface == srSurfaceField
    ck edge == srSurfaceTopBar
    ck not omnibarCaret(m, lay).shown
    ob.open()
    ob.typeText("calc")
    ob.moveCursor(-2)
    lay = topBarLayout(m, 200)
    let s2 = lay.segmentOf(tpOmnibar)
    let caret = omnibarCaret(m, lay)
    ck caret.shown and caret.row == 0
    ck caret.col == s2.col + OmnibarPad + 2 + 2      # "⌕ " then "ca"
    ck not caret.overwrite
    ob.toggleOverwrite()
    ck omnibarCaret(m, lay).overwrite

suite "PLAT-49: the variables rows carry their category, not a separator":

  test "no scope rows; each row's first cell is its category tag in its colour":
    let nodes = @[VarNode(path: "@Locals.a", name: "a", typeName: "Int",
                          value: "1"),
                  VarNode(path: "@Locals.b", name: "b", typeName: "Int",
                          value: "2")]
    var model = initVariablesModel(
      scopes = @[Scope(kind: skLocals, availability: savaAvailable),
                 Scope(kind: skArguments, availability: savaUnsupported,
                       note: "no argument surface")],
      children = proc(path: string; offset, limit: int):
                   tuple[nodes: seq[VarNode]; total: int] =
        (nodes: (if path == scopePath(skLocals): nodes else: @[]),
         total: (if path == scopePath(skLocals): nodes.len else: 0)))
    model.expandNode(scopePath(skLocals))
    let rows = model.paneRows()
    for r in rows:
      ck r.kind != vrkScope
    ck rows.len == 3
    let screen = variablesScreen(model, 60, 6)
    ck screen.scopeRows == 0
    let text = variablesText(model, 60, 6)
    ck text[1].startsWith("L ")
    ck text[2].startsWith("L ")
    ck text[3].startsWith("A ")
    ck screen.rows[1][0].style.role == srCategoryLocal
    ck screen.rows[3][0].style.role == srCategoryArgument
    ck screen.nameColumn == nameFieldColumn()
    ck text[1].runeSubStr(screen.nameColumn).startsWith("a")

suite "PLAT-49 shell: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
