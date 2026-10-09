## test_plat47_window_gestures.nim — PLAT-47 deliverables 5 and 6, GPUI's
## half, below the window. **The window's pixel geometry, its hit-test, and
## its divider and tab gestures, over the shared default the window opens
## with.**
##
## The geometry is `window_geometry.windowGeometryOf` over the REAL dock
## projection (`dock_projection.projectDock`) of the shared default layout —
## the computation the window draws its boxes from. The gestures are
## `window_gestures` driving the REAL `layout_interaction` machine; every
## command a release produces is applied through the REAL `layout_model
## .apply`, and the committed layout is projected again to measure what moved.
##
## What each case asserts is the arithmetic a user sees: a divider dragged by
## N pixels moves its pane's edge by N pixels (live, and committed); a press
## that is not on a divider resizes nothing; a tab dragged over each of the
## four drop kinds indicates exactly the region the model's `dropIndicationOf`
## names, and a release performs the indicated command; `Esc` leaves the
## committed layout exactly as it was. A pane DOCKED by a drop is not lost:
## it has a label in its edge's auto-hide strip, a click on the label reveals
## it over the tree (and a second click, `Esc` or a press elsewhere hides it
## again, the committed layout untouched), and dragging the label back into
## the tree places it there again.
##
## The window itself — the same gestures from a real pointer, read back from
## pixels — is `test_plat47_gpui_window.nim`, over the committed record.
##
## No mocks: the real layout model, projection, geometry and gesture code.

import std/[json, options, strutils, unittest]

import gpui/window_geometry
import gpui/window_gestures
import gpui/app/dock_projection
import gpui/chrome

const
  W = 1440
  H = 900
  ExpectedAssertions = 130

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

proc geometryOf(layout: Layout): WindowGeometry =
  let proj = projectDock(layout, DockViewport(width: W, height: H,
                                              dockExtent: 240))
  doAssert proj.status == dpsProjected
  windowGeometryOf(layout, proj.state, W, H)

proc nodeOf(g: WindowGeometry; pane: string): GeomNode =
  let i = g.tabsNodeOfPane(pane)
  doAssert i >= 0, pane & " is not drawn"
  g.nodes[i]

proc centre(r: PxRect): (int, int) = (r.x + r.w div 2, r.y + r.h div 2)

proc describe(r: PxRect): string =
  $r.x & "," & $r.y & " " & $r.w & "x" & $r.h

proc `$`(g: WindowGeometry): string =
  ## A one-line-per-node dump, for a checkpoint.
  var lines: seq[string] = @[]
  for n in g.nodes:
    case n.kind
    of gnSplit:
      lines.add "split '" & n.path & "' " & describe(n.rect) &
        (if n.horizontal: " row" else: " column")
    of gnTabs:
      lines.add "tabs '" & n.path & "' " & describe(n.rect) & " [" &
        n.panes.join(",") & "] active " & $n.active
  lines.join("\n")

let start = initLayout(sharedDefaultLayout().tree)
let g0 = geometryOf(start)

suite "PLAT-47: the window's geometry is total and exact":

  test "every pane box lies in the area, none overlaps another, the gaps are the dividers":
    checkpoint($g0)
    var boxes: seq[PxRect] = @[]
    for n in g0.nodes:
      if n.kind == gnTabs:
        boxes.add n.rect
        ck n.rect.x >= g0.area.x and n.rect.y >= g0.area.y and
           n.rect.x + n.rect.w <= g0.area.x + g0.area.w and
           n.rect.y + n.rect.h <= g0.area.y + g0.area.h
    var overlaps = 0
    for i in 0 ..< boxes.len:
      for j in i + 1 ..< boxes.len:
        let a = boxes[i]
        let b = boxes[j]
        if a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and
           b.y < a.y + a.h:
          inc overlaps
    ck boxes.len == 5   # Files, editor, Variables, Call Trace, Event Log
    ck overlaps == 0
    # One divider per adjacent sibling pair of every row and column.
    var pairs = 0
    for n in g0.nodes:
      if n.kind == gnSplit: pairs += n.children.len - 1
    ck g0.dividers.len == pairs
    for d in g0.dividers:
      ck (if d.horizontal: d.rect.w else: d.rect.h) == ChromeGapPx

  test "the hit-test: a tab, the strip past the tabs, the four bands, the centre, the margins":
    let files = g0.nodeOf("fileTree")
    ck files.stacked and files.tabs.len == 3
    # PLAT-49 part B: a tab's LEFT half inserts before it, its right half
    # after it (GoldenLayout's header rule).
    let (vx, vy) = (files.tabs[1].x + 2, centre(files.tabs[1])[1])
    let onVcs = g0.pointerAt(vx, vy)
    ck onVcs.isSome and onVcs.get.zone == dzTabStrip
    ck onVcs.get.path == files.path & "/1"
    let rightOfVcs = g0.pointerAt(files.tabs[1].x + files.tabs[1].w - 3, vy)
    ck rightOfVcs.isSome and rightOfVcs.get.path == files.path & "/2"
    let past = g0.pointerAt(files.tabs[^1].x + files.tabs[^1].w + 3, vy)
    ck past.isSome and past.get.zone == dzCentre
    let editor = g0.nodeOf("editor")
    let b = editor.body
    let (cx, cy) = centre(b)
    ck g0.pointerAt(cx, cy).get.zone == dzCentre
    ck g0.pointerAt(b.x + 2, cy).get.zone == dzLeftEdge
    ck g0.pointerAt(b.x + b.w - 3, cy).get.zone == dzRightEdge
    # The editor meets the layout's top and bottom edges: there, within
    # GoldenLayout's 50 px ground band, a drop splits the WHOLE layout
    # (PLAT-49 part B review); just inside the band, the pane's own quarter.
    ck g0.pointerAt(cx, b.y + 2).get.zone == dzRootTop
    ck g0.pointerAt(cx, b.y + b.h - 3).get.zone == dzRootBottom
    ck g0.pointerAt(cx, max(b.y, g0.inner.y + 50) + 2).get.zone == dzTopEdge
    ck g0.pointerAt(cx, min(b.y + b.h, g0.inner.y + g0.inner.h - 50) - 3).get.zone ==
       dzBottomEdge
    # PLAT-51 (GoldenLayout's hit-testing, ported): a pointer outside the
    # layout is constrained onto its edge (`constrainDragToContainer`) — the
    # margins are the ground's side bands, and no drop docks. GoldenLayout
    # rounds the right / bottom edge ONTO `x2` / `y2`, which its half-open
    # `getArea` excludes: past them a fresh drag finds nothing (a drag in
    # flight keeps its last valid area) — its asymmetry, kept.
    ck g0.pointerAt(3, H div 2).get.zone == dzRootLeft
    ck g0.pointerAt(W - 3, H div 2).isNone
    ck g0.pointerAt(W div 2, H - 3).isNone
    let above = g0.pointerAt(W div 2, 3)
    ck above.isSome and above.get.zone in {dzRootTop, dzTabStrip}

suite "the editor pane shows whole rows":

  test "the editor's fetch window is the rows its pane shows at the row pitch":
    # Every row a full line high (`GpuiEditorRowPx`): as many as fit below
    # the source statement (no heading since PLAT-49: the pane's tab strip,
    # outside its body, names it), and not one more — a window
    # holding more was squeezed into the pane, clipping every descender.
    let body = g0.nodeOf("editor").body
    let rows = editorRowsOf(g0)
    checkpoint("editor body " & describe(body) & " rows " & $rows)
    let used = 2 * ChromePaddingPx + EditorLinesAbovePx
    ck rows * GpuiEditorRowPx + used <= body.h
    ck (rows + 1) * GpuiEditorRowPx + used > body.h
    # A taller editor holds more.
    let tall = geometryOf(start).editorRowsOf()
    ck windowGeometryOf(start, projectDock(start, DockViewport(width: W,
         height: 2 * H, dockExtent: 240)).state, W, 2 * H).editorRowsOf() >
       tall

suite "PLAT-47 deliverable 5: dragging a divider":

  test "a divider dragged 80 px moves its pane's edge 80 px, live and committed":
    let d = g0.dividers[0]          # between Files and the editor
    ck d.container == "" and d.index == 0 and d.horizontal
    let filesBefore = g0.nodeOf("fileTree").rect
    var gest = idle()
    let (px, py) = centre(d.rect)
    discard gest.pointerDown(start, g0, px, py)
    ck gest.kind == gkResize
    let moved = gest.pointerMove(start, g0, px + 80, py)
    ck moved.changed
    # THE LIVE PREVIEW is the model's pending command applied.
    let live = geometryOf(gest.previewLayout(start))
    let filesLive = live.nodeOf("fileTree").rect
    checkpoint("files " & describe(filesBefore) & " -> " & describe(filesLive))
    ck abs(filesLive.w - (filesBefore.w + 80)) <= 1
    # The committed layout is untouched while the gesture is in flight.
    ck geometryOf(start).nodeOf("fileTree").rect == filesBefore
    let up = gest.pointerUp(start, g0, px + 80, py)
    ck up.command.isSome
    ck up.command.get.kind == lcSetWeight
    let applied = apply(start, up.command.get)
    ck applied.kind == loApplied
    let after = geometryOf(applied.layout).nodeOf("fileTree").rect
    ck abs(after.w - (filesBefore.w + 80)) <= 1
    ck not gest.active

  test "a press that is not on a divider resizes nothing":
    var gest = idle()
    let (cx, cy) = centre(g0.nodeOf("editor").body)
    discard gest.pointerDown(start, g0, cx, cy)
    ck gest.kind == gkNone
    discard gest.pointerMove(start, g0, cx + 80, cy)
    let up = gest.pointerUp(start, g0, cx + 80, cy)
    ck up.command.isNone
    ck geometryOf(gest.previewLayout(start)).nodeOf("fileTree").rect ==
       g0.nodeOf("fileTree").rect

suite "PLAT-47 deliverable 6: dragging a tab — the drop indication":

  let state = g0.nodeOf("state")
  let (sx, sy) = centre(state.tabs[0])      # the Variables tab

  proc lift(gest: var WindowGestures): WindowGeometry =
    ## Pick the Variables tab up and move past the slop. PLAT-51:
    ## GoldenLayout's drag proxy lifts the pane out before anything is
    ## measured, so the window is laid out again without it — the frame
    ## every later sample is aimed in and decided against.
    discard gest.pointerDown(start, g0, sx, sy)
    doAssert gest.kind == gkDragTab and gest.source == paneState
    let step = gest.pointerMove(start, g0, sx + 12, sy + 12)
    doAssert step.relayout
    geometryOf(gest.previewLayout(start))

  test "the drag lifts the pane: the window is laid out without it":
    var gest = idle()
    let gd = gest.lift()
    ck gd.tabsNodeOfPane("state") < 0
    ck gd.tabsNodeOfPane("editor") >= 0

  test "a split: the half of the target pane on the drop's side":
    var gest = idle()
    let gd = gest.lift()
    let editor = gd.nodeOf("editor")
    let eb = editor.body
    let (px, py) = (eb.x + eb.w - 3, eb.y + eb.h div 2)
    discard gest.pointerMove(start, gd, px, py)
    let ind = gest.indication()
    ck ind.kind == diSplitHalf and ind.side == leRight
    let (tint, caret) = gd.dropIndicationRects(ind)
    # The tint is the half of the pane's CONTENT (below its strip), as
    # GoldenLayout highlights half of a stack's content area.
    ck tint == halfOf(editor.body, leRight)
    ck caret.isEmpty
    # Release: the split the indication named is what is committed.
    let up = gest.pointerUp(start, gd, px, py)
    ck up.command.isSome
    let applied = apply(start, up.command.get)
    ck applied.kind == loApplied
    let after = geometryOf(applied.layout)
    let ed = after.nodeOf("editor").rect
    let st = after.nodeOf("state").rect
    # The Variables pane now sits RIGHT of the editor, in what was its box.
    ck st.x > ed.x and abs(st.y - ed.y) <= 1
    ck st.x + st.w <= editor.rect.x + editor.rect.w + 1

  test "a join onto a bare pane: the SMALLER middle of its body":
    var gest = idle()
    let gd = gest.lift()
    let editor = gd.nodeOf("editor")
    let (cx, cy) = centre(editor.body)
    discard gest.pointerMove(start, gd, cx, cy)
    let ind = gest.indication()
    # The user's middle joins after the last tab — the bare pane's one-tab
    # strip, slot 1 — and is highlighted on the strip, where the tab goes.
    ck ind.kind == diTabSlot and ind.slot == 1
    ck gd.dropIndicationRects(ind).tint == editor.strip
    # Outside the centred third, GoldenLayout's own split (top / bottom).
    discard gest.pointerMove(start, gd, cx, editor.body.y +
                                            editor.body.h div 5)
    let above = gest.indication()
    ck above.kind == diSplitHalf and above.side == leTop

  test "a join into a stack: its tab strip, and the placeholder at the slot":
    var gest = idle()
    let gd = gest.lift()
    let ct = gd.nodeOf("calltrace")
    # The LEFT half of tab 1: GoldenLayout inserts before a tab whose
    # midpoint the pointer has not passed.
    let tx = ct.tabs[1].x + ct.tabs[1].w div 4
    let ty = ct.tabs[1].y + ct.tabs[1].h div 2
    discard gest.pointerMove(start, gd, tx, ty)
    let ind = gest.indication()
    ck ind.kind == diTabSlot and ind.slot == 1
    let ph = gest.placeholderOf()
    ck ph.found and ph.stackPath == ct.path and ph.index == 1
    let (tint, caret) = gd.dropIndicationRects(ind, GlPlaceholderPx.int)
    ck tint == ct.strip
    ck not caret.isEmpty
    ck caret.x == ct.tabs[1].x and caret.w == GlPlaceholderPx.int
    let up = gest.pointerUp(start, gd, tx, ty)
    ck up.command.isSome
    let applied = apply(start, up.command.get)
    ck applied.kind == loApplied
    let joined = geometryOf(applied.layout).nodeOf("calltrace")
    ck joined.panes == @["calltrace", "state", "agentActivity"]

  test "the window's margin: GoldenLayout's ground band, a split of the whole layout":
    var gest = idle()
    let gd = gest.lift()
    discard gest.pointerMove(start, gd, 4, H div 2)
    let ind = gest.indication()
    ck ind.kind == diRootBand and ind.side == leLeft
    let tint = gd.dropIndicationRects(ind).tint
    ck tint == gd.rootBandOf(leLeft)
    let up = gest.pointerUp(start, gd, 4, H div 2)
    ck up.command.isSome
    let applied = apply(start, up.command.get)
    ck applied.kind == loApplied
    ck applied.layout.dockedAt(leLeft).len == 0

  test "Esc cancels: nothing is indicated and the committed layout is the start":
    var gest = idle()
    let gd = gest.lift()
    let eb = gd.nodeOf("editor").body
    discard gest.pointerMove(start, gd, eb.x + eb.w - 3, eb.y + eb.h div 2)
    ck gest.indication().kind == diSplitHalf
    let step = gest.cancelGesture()
    ck step.changed
    ck gest.indication().kind == diNone
    ck $saveLayout(gest.previewLayout(start)) == $saveLayout(start)
    let up = gest.pointerUp(start, g0, eb.x + eb.w - 3, eb.y + eb.h div 2)
    ck up.command.isNone

  test "a click on a tab (no motion past the slop) activates it":
    var gest = idle()
    let files = g0.nodeOf("fileTree")
    let (vx, vy) = centre(files.tabs[1])
    discard gest.pointerDown(start, g0, vx, vy)
    discard gest.pointerMove(start, g0, vx + 2, vy + 1)
    ck gest.indication().kind == diNone
    let up = gest.pointerUp(start, g0, vx + 2, vy + 1)
    ck up.command.isSome and up.command.get.kind == lcActivateTab
    let applied = apply(start, up.command.get)
    ck applied.kind == loApplied
    ck geometryOf(applied.layout).nodeOf("vcs").active == 1

suite "a docked pane stays on screen: its strip, its reveal, its way back":

  let state = g0.nodeOf("state")
  let (sx, sy) = centre(state.tabs[0])      # the Variables tab

  # Dock the Variables pane on the left edge. PLAT-51: GoldenLayout docks
  # nothing on a drop, so the dock is the pane menu's command.
  discard (sx, sy)
  let docked = apply(start, cmdDock(paneState, leLeft))
  let dl = if docked.kind == loApplied: docked.layout else: start
  let gd = geometryOf(dl)

  test "the docked pane leaves the tree and gets a label in the left strip":
    ck docked.kind == loApplied
    ck dl.dockedAt(leLeft).len == 1
    ck gd.tabsNodeOfPane("state") < 0
    ck gd.strips.len == 1 and gd.strips[0].edge == leLeft
    let st = gd.strips[0]
    ck st.slots.len == 1 and st.slots[0].pane == "state"
    # The strip takes the area's left edge; the tree what is left of it.
    ck st.rect.x == gd.area.x and st.rect.w == DockStripPx and
       st.rect.h == gd.area.h
    ck gd.inner.x == gd.area.x + DockStripPx + ChromeGapPx
    ck gd.inner.w == gd.area.w - DockStripPx - ChromeGapPx
    for n in gd.nodes:
      if n.kind == gnTabs:
        ck n.rect.x >= gd.inner.x
    # A left strip's label reads down: one character per row.
    ck st.slots[0].rect.h == slotExtentPx(leLeft, st.slots[0].label)
    # PLAT-51: a pointer over the strip is outside the tree, constrained onto
    # its edge — GoldenLayout's ground band; no drop docks.
    let (lx, ly) = centre(st.slots[0].rect)
    ck gd.pointerAt(lx, ly).get.zone == dzRootLeft

  test "a click on the label docks the pane open; a second closes it; a hover previews it":
    # PLAT-49 part B (the user's direction): A CLICK DOCKS THE PANE OPEN —
    # beside the tree, which gives up a band for it — and a second click
    # closes it; the overlay over the tree is the HOVER's preview.
    let (lx, ly) = centre(gd.strips[0].slots[0].rect)
    var gest = idle()
    discard gest.pointerDown(dl, gd, lx, ly)
    ck gest.kind == gkDragTab and gest.fromStrip
    let up = gest.pointerUp(dl, gd, lx + 1, ly)
    ck up.changed and up.command.isSome
    ck up.command.get.autoHideDirection == ahOpen
    ck not gest.revealing
    let opened = apply(dl, up.command.get)
    ck opened.kind == loApplied
    let go = geometryOf(opened.layout)
    ck go.openDockPane == "state"
    ck go.openDock.x == gd.inner.x and go.openDock.h == gd.inner.h
    ck go.inner.x == go.openDock.x + go.openDock.w + ChromeGapPx
    for n in go.nodes:
      if n.kind == gnTabs:
        ck n.rect.x >= go.inner.x
    var gest2 = idle()
    discard gest2.pointerDown(opened.layout, go, lx, ly)
    let closeUp = gest2.pointerUp(opened.layout, go, lx, ly)
    ck closeUp.command.isSome and
       closeUp.command.get.autoHideDirection == ahClose
    # The hover's preview: over the tree, against its edge.
    ck gest.previewReveal(dl, paneState)
    ck gest.revealing and gest.reveal.pane == paneState and
       gest.reveal.edge == leLeft
    let rr = gd.revealRectOf(leLeft)
    ck rr.x == gd.inner.x and rr.h == gd.inner.h and
       rr.w == gd.inner.w div RevealShareDenominator
    # A press INSIDE the revealed pane is the pane's own: it stays.
    let (rx, ry) = centre(rr)
    discard gest.pointerDown(dl, gd, rx, ry)
    ck gest.revealing
    discard gest.pointerUp(dl, gd, rx, ry)
    ck gest.revealing
    # The pointer leaving ends the preview (`dismissReveal`).
    ck gest.dismissReveal(paneState)
    ck not gest.revealing

  test "Esc, or a press outside the revealed pane, hides it; the layout never moved":
    var gest = idle()
    ck gest.previewReveal(dl, paneState)
    ck gest.revealing
    ck gest.cancelGesture().changed
    ck not gest.revealing
    ck gest.previewReveal(dl, paneState)
    ck gest.revealing
    # A point in the tree well right of the revealed third.
    let (ex, ey) = (gd.inner.x + gd.inner.w - 40, gd.inner.y + gd.inner.h div 4)
    ck ex > gd.revealRectOf(leLeft).x + gd.revealRectOf(leLeft).w
    ck gd.tabsNodeAt(ex, ey) >= 0
    let press = gest.pointerDown(dl, gd, ex, ey)
    ck press.changed and not gest.revealing
    discard gest.pointerUp(dl, gd, ex, ey)
    ck $saveLayout(gest.previewLayout(dl)) == $saveLayout(dl)

  test "dragging the label back into the tree places the pane there again":
    let (lx, ly) = centre(gd.strips[0].slots[0].rect)
    var gest = idle()
    discard gest.pointerDown(dl, gd, lx, ly)
    discard gest.pointerMove(dl, gd, lx + 12, ly + 12)
    # The frame the drag draws: the label lifted out of its strip.
    let gl = geometryOf(gest.previewLayout(dl))
    let eb = gl.nodeOf("editor").body
    discard gest.pointerMove(dl, gl, eb.x + eb.w - 3, eb.y + eb.h div 2)
    ck gest.indication().kind == diSplitHalf
    let up = gest.pointerUp(dl, gl, eb.x + eb.w - 3, eb.y + eb.h div 2)
    ck up.command.isSome
    let back = apply(dl, up.command.get)
    ck back.kind == loApplied
    ck back.layout.dockedAt(leLeft).len == 0
    let gb = geometryOf(back.layout)
    ck gb.strips.len == 0 and gb.inner == gb.area
    ck gb.tabsNodeOfPane("state") >= 0

suite "assertion tally":
  test "count":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedAssertions
