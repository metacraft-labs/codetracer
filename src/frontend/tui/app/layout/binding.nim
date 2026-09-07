## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. Nothing here touches a terminal, reads a key or writes a byte:
## this module turns VALUES into VALUES.
##
## app/layout/binding.nim — PLAT-6. The terminal front-end's **binding** to
## Layout-ViewModel's layout model.
##
## ## What a binding owes, and where each obligation is discharged here
##
## Layout-ViewModel §5 says a binding owes four things and nothing else:
##
##   1. **Project** — `app/layout/project.projectLayout`, which CTUI-3 already
##      shipped and which this module composes with the dock strips rather than
##      replacing. `geometryOf` is that composition.
##   2. **Hit-test** — `pointerAt` (cells -> a `LayoutPointer`) and `cellsFor`
##      (a `DropRegion` -> the cells to draw). **THIS IS THE HALF PLAT-5
##      DELIBERATELY LEFT FOR PLAT-6**, and it is why `LayoutPointer` carries
##      no numeric field: the conversion between a medium and the model's
##      vocabulary lives here, in the medium that has cells, and nowhere below.
##   3. **Draw transient state** — `decorationsFor`, read from `Interaction`,
##      never stored: the drag ghost, the highlighted drop target, the resize
##      guide, the dock strips and the reveal overlay are all DERIVED per frame
##      from the committed layout plus the gesture in flight.
##   4. **Emit gestures** — `onMouse` over `app/input/mouse.MouseEvent`, and
##      `runLayoutCommand` for the keyboard, since a terminal user may have no
##      pointer at all.
##
## ## A BINDING NEVER DECIDES LAYOUT SEMANTICS
##
## §5, verbatim: "If a renderer needs a rule the model does not have, the rule
## is missing from the model." So there is no legality test in this file. Every
## gesture is turned into a `LayoutCommand` and handed to
## `layout_interaction`/`layout_model`; `apply` decides, and this module
## reports what it decided. Concretely:
##
##   * `dropTargetsFor` is the ONLY source of candidates. This module does not
##     filter them, add to them, or decide that one of them is illegal.
##   * `commit` is the only thing that says a drop produced a command, and it
##     says so by asking `apply`, so a drag landing where it started commits
##     nothing here for exactly the reason §2.3 gives for `loNoOp` existing.
##   * the collapse rules are never re-stated. Dropping the last tab out of a
##     stack collapses that stack because `lcMoveTab`'s pass does it, and the
##     binding's own test asserts the collapsed SHAPE through this surface
##     rather than through `apply` directly.
##
## ## THIS MODULE HOLDS NO `LayoutNode` REFERENCE, AND THAT IS STRUCTURAL
##
## `layout_interaction.nodeAtPath` hands out a live `ref` into the committed
## tree, so a caller can write through it. PLAT-6 is the first real caller and
## it takes the other door: `nodeInfoAtPath` returns a `NodeInfo`, every field
## of which is a copied scalar. Nothing in this file names `nodeAtPath` or
## `layout_model.find`, no signature here mentions `LayoutNode`, and
## `app/tests/test_layout_binding.nim` asserts both — the field walk over
## `NodeInfo` with a counted control, and the absence of the two call sites
## with a positive control that the scan reads this file at all.
##
## Stated exactly, because the difference matters: this module never RESOLVES A
## PATH TO A NODE. It names `layout.tree` in seven places, and six of them hand
## it straight to `nodeInfoAtPath` — which is the value-returning door, so what
## comes back is a `NodeInfo` and not a node. The seventh hands the ROOT to
## `project.projectLayout`, which is the projection this binding exists to
## compose with. No local here is ever a `LayoutNode`.
##
## What that does NOT close is recorded at `NodeInfo`'s own declaration:
## `Layout.tree` is a public `ref` field, so anybody holding a `Layout` can
## still write through it without calling anything. Closing that needs `Layout`
## to stop publishing a mutable tree, which is a change to the persisted
## model's representation and belongs to whoever owns that model.
##
## ## THE RESPONSIVE-PROFILE DECISION (Layout-ViewModel §8.2 and §8.4)
##
## The spec calls the three profiles "currently neither" re-flows of one
## default nor deliberately divergent. **PLAT-6 decides: deliberately
## divergent, and a user modification freezes the profile.**
##
## Divergent, because the profiles are not three renderings of one arrangement
## — they show DIFFERENT PANE SETS (Compact has no event-log column and folds
## three panes into a stack; Ultra-wide gives the event log a column of its
## own), and each is chosen by `profile.minPaneWidth`/`minPaneHeight`, a
## minimum-size contract in CELLS that the headless default has no concept of
## and could not carry without putting a measurement in the model.
##
## Frozen, because §8.4 asks which wins when a saved layout meets a responsive
## re-flow, and the answer that does not lose a user's work is: the profile
## produces the DEFAULT layout and stops there. `resize` re-flows only while
## `userModified` is false; the first applied command sets it, and
## `resetToProfile` is the explicit way back. That is §8.4's own
## recommendation, implemented rather than recommended.

import std/[json, options, strutils]

import headless_app/layout_interaction
import headless_app/layout_model

import ../input/motions
import ../input/mouse
import ../views/header
import ../views/styled_row
import ./profile
import ./project
import ./tab_strip

export layout_interaction, layout_model
export profile, project, tab_strip
export mouse, motions

type
  DockStripSlot* = object
    ## One auto-hidden pane's tab within its edge strip.
    pane*: PaneKind
    title*: string
    order*: int
    area*: CellArea
      ## Absolute cells. A click here is what reveals the pane, and a drag from
      ## here is how it is undocked, so the rectangle is reported rather than
      ## recomputed by a caller.

  DockStrip* = object
    ## One edge's auto-hide strip (§3.1's collapsed icons, in a terminal).
    edge*: LayoutEdge
    area*: CellArea
    slots*: seq[DockStripSlot]

  LayoutGeometry* = object
    ## Everything a frame needs to know about where the layout is.
    ##
    ## Derived, per frame, from a `Layout` and a body rectangle. Held by
    ## nobody: a geometry that outlived the layout it came from would be the
    ## stale-screen defect CTUI-3's reflow suite exists to catch.
    body*: CellArea
      ## Everything the layout owns — `profile.bodyArea`, between the header
      ## and the status bar.
    inner*: CellArea
      ## `body` minus the dock strips: what the TREE is projected into. The
      ## split tree's partition is total over THIS, not over `body`, which is
      ## what keeps `project.coverageProblems` meaningful once panes are
      ## docked.
    projection*: Projection
    strips*: seq[DockStrip]
    paths*: seq[(PaneKind, string)]
      ## Every VISIBLE pane and its node path, resolved once. A pane that is
      ## docked or on the hidden side of a stack is absent, exactly as it is
      ## absent from `projection.regions`.
    revealing*: bool
    revealPane*: PaneKind
    reveal*: CellArea
      ## Where a revealed dock overlay is painted, or a zero rectangle. An
      ## OVERLAY: it is deliberately not one of the projection's rectangles,
      ## for the reason `views/shell.tracepointOverlayArea` gives about the
      ## tracepoint dialog — a docked pane that took a share of the layout
      ## would shrink the tree every time a user peeked at it.

  LayoutDecorationKind* = enum
    ## What a renderer draws that is not a pane. §5's third obligation.
    ldDockStrip = "dockStrip"
    ldDragGhost = "dragGhost"
      ## Where the dragged pane currently lives — the thing the user is
      ## "carrying".
    ldDropTarget = "dropTarget"
      ## The one candidate the pointer is on. Highlighted without re-checking
      ## anything, because `dropTargetsFor` already filtered through `apply`.
    ldResizeGuide = "resizeGuide"
      ## Where the divider would land if the resize committed now.
    ldRevealOverlay = "revealOverlay"

  LayoutDecoration* = object
    ## One thing to draw, as a rectangle and a label. Deliberately NOT a style:
    ## `app/theme/degradation.nim` re-styles a composited screen by semantic
    ## role, and a decoration that carried its own colour would bypass it.
    kind*: LayoutDecorationKind
    area*: CellArea
    label*: string

  LayoutActionStatus* = enum
    ## What a gesture did. Every value carries a message; see `LayoutAction`.
    lasNoGesture = "no-gesture"
      ## The event was not a layout gesture at all — an ordinary click in a
      ## pane's body, a key this surface does not own.
    lasPending = "pending"
      ## A gesture began or moved. Nothing is committed; `Interaction` changed.
    lasApplied = "applied"
    lasNoOp = "no-op"
      ## `apply` answered `loNoOp`: legal, and the layout is already like that.
      ## Distinct from `lasApplied` for §2.3's reason — no undo entry.
    lasRefused = "refused"
    lasCancelled = "cancelled"
    lasUnknownCommand = "unknown-command"
    lasBadArgument = "bad-argument"

  LayoutAction* = object
    ## The result of one gesture. `message` is NEVER empty, on CTUI-10's rule
    ## for the command line: "an unknown command reports it; it never silently
    ## does nothing", which is as true of a mouse gesture that landed nowhere.
    status*: LayoutActionStatus
    message*: string
    command*: Option[LayoutCommand]
      ## The command the gesture produced, when it produced one. Reported so a
      ## test asserts the MODEL operation rather than the screen — PLAT-6's
      ## "asserted on the resulting layout, not on the screen alone".
    problem*: Option[LayoutProblem]
      ## Set for `lasRefused`, so a caller can say WHY by kind.

  LayoutBinding* = ref object
    ## The terminal's layout state: the committed layout with its undo log, the
    ## gesture in flight, and the two facts a terminal adds — which pane has
    ## focus, and whether the user has touched the arrangement.
    ##
    ## A `ref` because a front-end holds one for the life of a session and
    ## every gesture mutates it; everything it ANSWERS is a value.
    history*: LayoutHistory
    interaction*: Interaction
    profile*: LayoutProfile
    focus*: PaneKind
    userModified*: bool
      ## Set by the first command that applies. See the module header on the
      ## responsive-profile decision this implements.
    pressRow*: int
    pressCol*: int
      ## Where the last press landed, so a release at the SAME cell can be told
      ## from a drag. -1 when no button is down.

const
  DockStripThickness* = 1
    ## One row (top/bottom) or one column (left/right). A terminal's body is
    ## measured in a few dozen cells and a two-cell strip on two edges costs a
    ## Compact profile four of them; one cell is enough for a readable
    ## collapsed tab and is what §3.1's desktop strip degrades to.

  MaxEdgeBandCells* = 3
    ## The widest an edge drop-zone gets. Three cells is enough to aim at with
    ## a mouse and small enough that `dzCentre` stays reachable on a 14-column
    ## pane — `profile.minPaneWidth`'s narrowest.

  RevealShareDenominator* = 3
    ## A revealed dock overlay takes a third of the inner area's extent on its
    ## axis, clamped to at least one cell. A third rather than a half because
    ## the point of a peek is that the arrangement behind it is still readable.

  DockStripGlyph* = "·"
  DragGhostGlyph* = "░"
  DropTargetGlyph* = "▒"
  ResizeGuideGlyph* = "▓"
  RevealOverlayGlyph* = "▒"
    ## One-cell-wide fills, so a decoration's rune count is its cell count and
    ## `paintDecorations` cannot straddle a column. All four are U+2591..U+2593
    ## and U+00B7, which are narrow in every width table this tree uses.

# ---------------------------------------------------------------------------
# Geometry: the projection composed with the dock strips
# ---------------------------------------------------------------------------

proc isEmptyArea*(a: CellArea): bool =
  a.width <= 0 or a.height <= 0

proc edgeBandCells*(extent: int): int =
  ## How deep an edge drop-zone is on a side of `extent` cells.
  ##
  ## A quarter, capped, and at least one — so that every pane, however narrow,
  ## HAS all four edge zones (otherwise `dtSplitBefore` would be unreachable on
  ## a thin pane and a documented drop target would silently not exist), and
  ## every pane wide enough to have a centre keeps one.
  max(1, min(MaxEdgeBandCells, extent div 4))

proc stripAreaFor(body: CellArea; edge: LayoutEdge; left, right: int):
    CellArea =
  ## The strip rectangle for `edge` within `body`, given how many columns the
  ## left and right strips have already claimed.
  ##
  ## LEFT AND RIGHT FIRST, spanning the body's full height; TOP AND BOTTOM
  ## then take the width that is left. Stated here once because the corners
  ## have to belong to exactly one strip or `pointerAt` would answer two
  ## different dock edges for one cell.
  case edge
  of leLeft:
    CellArea(col: body.col, row: body.row, width: DockStripThickness,
             height: body.height)
  of leRight:
    CellArea(col: body.col + body.width - DockStripThickness, row: body.row,
             width: DockStripThickness, height: body.height)
  of leTop:
    CellArea(col: body.col + left, row: body.row,
             width: body.width - left - right, height: DockStripThickness)
  of leBottom:
    CellArea(col: body.col + left, row: body.row + body.height - DockStripThickness,
             width: body.width - left - right, height: DockStripThickness)

proc slotAreas(strip: CellArea; edge: LayoutEdge; count: int): seq[CellArea] =
  ## Divide a strip among `count` collapsed tabs.
  ##
  ## Through `project.distributeCells`, which is the SAME largest-remainder
  ## distribution the split tree is snapped with — so a strip's slots sum to
  ## the strip exactly and none of them is empty, by the properties that
  ## routine already carries and its own suite already asserts.
  result = @[]
  if count <= 0 or strip.isEmptyArea:
    return
  let horizontal = edge in {leTop, leBottom}
  let axis = if horizontal: strip.width else: strip.height
  var shares: seq[float] = @[]
  for _ in 0 ..< count:
    shares.add 1.0
  let sizes = distributeCells(axis, shares)
  if sizes.len == 0:
    # Fewer cells than tabs. Reported as no slots rather than as zero-width
    # ones: an empty rectangle a user can click is worse than a tab that is
    # honestly not drawn.
    return
  var cursor = if horizontal: strip.col else: strip.row
  for s in sizes:
    if horizontal:
      result.add CellArea(col: cursor, row: strip.row, width: s,
                          height: strip.height)
    else:
      result.add CellArea(col: strip.col, row: cursor, width: strip.width,
                          height: s)
    cursor += s

proc revealAreaFor(inner: CellArea; edge: LayoutEdge): CellArea =
  ## Where a revealed dock overlay is painted: against its own edge of the
  ## inner area, a third of that axis deep.
  if inner.isEmptyArea:
    return CellArea()
  case edge
  of leLeft:
    CellArea(col: inner.col, row: inner.row,
             width: max(1, inner.width div RevealShareDenominator),
             height: inner.height)
  of leRight:
    let w = max(1, inner.width div RevealShareDenominator)
    CellArea(col: inner.col + inner.width - w, row: inner.row, width: w,
             height: inner.height)
  of leTop:
    CellArea(col: inner.col, row: inner.row, width: inner.width,
             height: max(1, inner.height div RevealShareDenominator))
  of leBottom:
    let h = max(1, inner.height div RevealShareDenominator)
    CellArea(col: inner.col, row: inner.row + inner.height - h,
             width: inner.width, height: h)

proc geometryOf*(layout: Layout; body: CellArea;
                 interaction: Interaction = noInteraction();
                 policy: ProjectionPolicy = DefaultProjectionPolicy):
    LayoutGeometry =
  ## Where everything is, for one frame.
  ##
  ## THE DOCK STRIPS COME OUT OF THE BODY FIRST, and the tree is projected into
  ## what is left. That ordering is what keeps CTUI-3's invariant true and
  ## meaningful at the same time: the projection is still total and pairwise
  ## disjoint over `inner`, and `inner` plus the strips is `body` exactly, so
  ## nothing on screen belongs to nobody.
  result = LayoutGeometry(body: body, inner: body, strips: @[], paths: @[],
                          revealing: false, revealPane: PaneKind.low,
                          reveal: CellArea())
  var left = 0
  var rightW = 0
  for edge in [leLeft, leRight]:
    if layout.dockedAt(edge).len > 0:
      if edge == leLeft: left = DockStripThickness else: rightW = DockStripThickness
  var top = 0
  var bottom = 0
  for edge in [leTop, leBottom]:
    if layout.dockedAt(edge).len > 0:
      if edge == leTop: top = DockStripThickness else: bottom = DockStripThickness

  for edge in [leLeft, leRight, leTop, leBottom]:
    let docked = layout.dockedAt(edge)
    if docked.len == 0:
      continue
    let area = stripAreaFor(body, edge, left, rightW)
    var strip = DockStrip(edge: edge, area: area, slots: @[])
    let areas = slotAreas(area, edge, docked.len)
    for i, d in docked:
      strip.slots.add DockStripSlot(
        pane: d.pane, title: (if d.title.len > 0: d.title else: $d.pane),
        order: d.order,
        area: (if i < areas.len: areas[i] else: CellArea()))
    result.strips.add strip

  result.inner = CellArea(col: body.col + left, row: body.row + top,
                          width: max(0, body.width - left - rightW),
                          height: max(0, body.height - top - bottom))
  result.projection = projectLayout(layout.tree, result.inner, policy)
  for region in result.projection.regions:
    let p = panePath(layout, region.pane)
    if p.isSome:
      result.paths.add (region.pane, p.get)
  if interaction.kind == ikRevealingDock:
    result.revealing = true
    result.revealPane = interaction.pane
    result.reveal = revealAreaFor(result.inner, interaction.edge)

proc pathOfPane*(geom: LayoutGeometry; pane: PaneKind): Option[string] =
  ## The node path of a VISIBLE pane, out of the geometry's own resolution.
  for entry in geom.paths:
    if entry[0] == pane:
      return some(entry[1])
  none(string)

proc regionOfPane*(geom: LayoutGeometry; pane: PaneKind): CellArea =
  geom.projection.regionFor(pane)

proc regionIndexAt*(geom: LayoutGeometry; row, col: int): int =
  ## Which projected region owns the cell, or -1.
  for i, r in geom.projection.regions:
    if r.area.contains(row, col):
      return i
  -1

proc stripIndexAt*(geom: LayoutGeometry; row, col: int): int =
  for i, s in geom.strips:
    if s.area.contains(row, col):
      return i
  -1

proc slotAt*(strip: DockStrip; row, col: int): int =
  for i, s in strip.slots:
    if s.area.contains(row, col):
      return i
  -1

proc boundsOfPath*(geom: LayoutGeometry; path: string): CellArea =
  ## The cells the node at `path` occupies: the bounding box of every VISIBLE
  ## pane beneath it.
  ##
  ## A bounding box is EXACT here rather than an approximation, and the reason
  ## is `project.nim`'s own invariant: the projection is a rectangular
  ## partition in which every container's children tile it end to end on one
  ## axis and span it on the other. So the union of a subtree's rectangles IS a
  ## rectangle. For a stack only the active child is visible and its rectangle
  ## is the stack's whole region, which is the same statement. `cellsFor`'s
  ## own suite asserts the equality against `coverageProblems` rather than
  ## trusting this paragraph.
  var found = false
  var top, leftC, bottomC, rightC: int
  for i, entry in geom.paths:
    let p = entry[1]
    if not (path.len == 0 or p == path or p.startsWith(path & "/")):
      continue
    let a = geom.projection.regions[i].area
    if a.isEmptyArea:
      continue
    if not found:
      found = true
      top = a.row
      leftC = a.col
      bottomC = a.row + a.height
      rightC = a.col + a.width
    else:
      top = min(top, a.row)
      leftC = min(leftC, a.col)
      bottomC = max(bottomC, a.row + a.height)
      rightC = max(rightC, a.col + a.width)
  if not found:
    return CellArea()
  CellArea(col: leftC, row: top, width: rightC - leftC, height: bottomC - top)

type
  TabStripGeometry* = object
    ## Where a stack's tab strip is, and what is on it. The one answer both
    ## directions of the hit-test and the drag ghost read, so a caret, a
    ## highlight and a click cannot disagree about which column tab `i` starts
    ## at.
    found*: bool
    tabs*: seq[string]
    active*: int
    area*: CellArea
      ## The strip's own row: the stack's first row, its full width.

proc tabStripOf*(geom: LayoutGeometry; stackPath: string): TabStripGeometry =
  ## The tab strip of the stack at `stackPath`, or `found: false`.
  ##
  ## Only the ACTIVE tab has a projected rectangle, and that rectangle is the
  ## stack's whole region — so the strip is that rectangle's first row, and the
  ## labels are the `PaneRegion.tabs` the projection already carried out of the
  ## tree.
  result = TabStripGeometry(found: false, tabs: @[], active: -1,
                            area: CellArea())
  let bounds = geom.boundsOfPath(stackPath)
  if bounds.isEmptyArea:
    return
  for r in geom.projection.regions:
    if r.activeTab >= 0 and r.tabs.len > 0 and
       r.area.row == bounds.row and r.area.col == bounds.col:
      return TabStripGeometry(
        found: true, tabs: r.tabs, active: r.activeTab,
        area: CellArea(col: bounds.col, row: bounds.row, width: bounds.width,
                       height: 1))

proc dropAreaOfPath*(geom: LayoutGeometry; path: string): CellArea =
  ## `boundsOfPath` MINUS the tab strip, when the node at `path` is a tab of a
  ## stack.
  ##
  ## The strip is a drop region in its own right (`drTabSlot`), so a cell on it
  ## must not ALSO be inside the node's top edge band — one cell would then
  ## mean two things and the two directions of the hit-test would disagree
  ## about which. This is the single definition both directions read: the
  ## forward hit-test measures its edge bands against this rectangle, and
  ## `cellsFor` draws them against it.
  let bounds = geom.boundsOfPath(path)
  if bounds.isEmptyArea:
    return bounds
  for i, entry in geom.paths:
    if entry[1] != path:
      continue
    let region = geom.projection.regions[i]
    if region.activeTab >= 0 and region.tabs.len > 0 and
       region.area.row == bounds.row and bounds.height > 1:
      return CellArea(col: bounds.col, row: bounds.row + 1,
                      width: bounds.width, height: bounds.height - 1)
    break
  bounds

proc stripAreaOf*(geom: LayoutGeometry; edge: LayoutEdge): CellArea =
  ## The strip along `edge`, or — when nothing is docked there yet — the
  ## one-cell band along that edge of the body where one WOULD appear.
  ##
  ## A band rather than a zero rectangle, because a user must be able to see
  ## where a drag would dock a pane BEFORE anything is docked there. The
  ## highlight and the eventual strip are then the same cells.
  for s in geom.strips:
    if s.edge == edge:
      return s.area
  stripAreaFor(geom.body, edge, 0, 0)

# ---------------------------------------------------------------------------
# §5 obligation 2, first direction: CELLS -> `LayoutPointer`
# ---------------------------------------------------------------------------

proc nearestOutsideZone(body: CellArea; row, col: int): DropZone =
  ## Which dock edge a cell outside the tree belongs to.
  ##
  ## By smallest signed distance to each side, ties broken left, right, top,
  ## bottom — a total function, because a pointer that resolved to NOTHING
  ## while a drag was in flight would make the drag silently undroppable at the
  ## screen's corners.
  let dl = col - body.col
  let dr = body.col + body.width - 1 - col
  let dt = row - body.row
  let db = body.row + body.height - 1 - row
  var best = dl
  var zone = dzOutsideLeft
  if dr < best:
    best = dr
    zone = dzOutsideRight
  if dt < best:
    best = dt
    zone = dzOutsideTop
  if db < best:
    zone = dzOutsideBottom
  zone

proc pointerAt*(layout: Layout; geom: LayoutGeometry;
                row, col: int): Option[LayoutPointer] =
  ## **The hit-test.** A terminal cell, in the layout's own vocabulary.
  ##
  ## `LayoutPointer` has no numeric field, which is exactly why this routine
  ## has to exist and has to live in a module that knows what a cell is. Below
  ## it there is no medium left to disagree about; above it a pixel front-end
  ## writes its own and calls the same `dropTargetsFor`.
  ##
  ## The resolution order, and every step of it is a decision rather than an
  ## implementation detail:
  ##
  ##   1. **A dock strip wins over everything.** The strips are the terminal's
  ##      spelling of §4.2.1's "strips outside the body", so a cell in one is
  ##      `dzOutside<edge>` — which is what makes dropping onto a strip dock a
  ##      pane.
  ##   2. **Anything outside the tree area is the nearest dock edge**, so a
  ##      drag that leaves the body still names a target rather than going
  ##      dead.
  ##   3. **A stacked pane's first row is its tab strip**, and the path
  ##      answered there is the path of the tab UNDER THE CURSOR — which may be
  ##      an inactive tab with no rectangle of its own. That is the whole
  ##      reason this needs the tree and not only the projection, and it is
  ##      what makes "drop between two tabs" expressible: `regionForZone` turns
  ##      `dzTabStrip` on tab `i` into slot `i`.
  ##   4. **The filler past the last tab is `dzCentre`**, which
  ##      `regionForZone` reads as "append", so the obvious gesture (drop on
  ##      the empty part of a tab bar) appends rather than doing nothing.
  ##   5. **Then the four edge bands, then the centre.** Nearest side wins;
  ##      ties go left, right, top, bottom. Total and disjoint over the
  ##      region's cells by construction, which the suite re-derives by
  ##      sweeping every cell.
  let strip = geom.stripIndexAt(row, col)
  if strip >= 0:
    let edge = geom.strips[strip].edge
    let zone = case edge
      of leLeft: dzOutsideLeft
      of leRight: dzOutsideRight
      of leTop: dzOutsideTop
      of leBottom: dzOutsideBottom
    return some(LayoutPointer(path: "", zone: zone))
  if not geom.inner.contains(row, col):
    return some(LayoutPointer(path: "",
                              zone: nearestOutsideZone(geom.body, row, col)))
  let idx = geom.regionIndexAt(row, col)
  if idx < 0:
    # Inside the tree area but owned by no pane. That is a projection defect —
    # `coverageProblems` calls it `cpUncovered` — and the honest answer is
    # `none` rather than a nearby pane, so a caller reports "nothing here"
    # instead of acting on a guess.
    return none(LayoutPointer)
  let region = geom.projection.regions[idx]
  let a = region.area
  let stacked = region.activeTab >= 0 and region.tabs.len > 0
  let panePath = geom.pathOfPane(region.pane)
  if panePath.isNone:
    return none(LayoutPointer)
  if stacked and row == a.row:
    let flushRight = a.col + a.width >= geom.inner.col + geom.inner.width
    let inner = if flushRight: a.width else: a.width - 1
    if col - a.col < inner:
      let at = tabSpanAt(region.tabs, region.activeTab, col - a.col)
      if at >= 0:
        let stackPath = parentPath(panePath.get)
        if stackPath.isSome:
          return some(LayoutPointer(path: childPathOf(stackPath.get, at),
                                    zone: dzTabStrip))
      # The filler rule past the last label.
      return some(LayoutPointer(path: panePath.get, zone: dzCentre))
  # THE SAME RECTANGLE `cellsFor` draws against — see `dropAreaOfPath`. Read
  # from there rather than recomputed here, so the two directions of the
  # hit-test cannot disagree about where a node's edge bands are.
  let area = geom.dropAreaOfPath(panePath.get)
  if area.isEmptyArea or not area.contains(row, col):
    return some(LayoutPointer(path: panePath.get, zone: dzCentre))
  let dl = col - area.col
  let dr = area.col + area.width - 1 - col
  let dt = row - area.row
  let db = area.row + area.height - 1 - row
  let bandH = edgeBandCells(area.width)
  let bandV = edgeBandCells(area.height)
  var zone = dzCentre
  var best = high(int)
  if dl < bandH and dl < best:
    best = dl
    zone = dzLeftEdge
  if dr < bandH and dr < best:
    best = dr
    zone = dzRightEdge
  if dt < bandV and dt < best:
    best = dt
    zone = dzTopEdge
  if db < bandV and db < best:
    zone = dzBottomEdge
  some(LayoutPointer(path: panePath.get, zone: zone))

# ---------------------------------------------------------------------------
# §5 obligation 2, second direction: `DropRegion` -> CELLS
# ---------------------------------------------------------------------------

proc stripOf(area: CellArea; side: LayoutEdge): CellArea =
  ## A band along one side of a rectangle, `edgeBandCells` deep.
  if area.isEmptyArea:
    return CellArea()
  case side
  of leLeft:
    CellArea(col: area.col, row: area.row,
             width: edgeBandCells(area.width), height: area.height)
  of leRight:
    let w = edgeBandCells(area.width)
    CellArea(col: area.col + area.width - w, row: area.row, width: w,
             height: area.height)
  of leTop:
    CellArea(col: area.col, row: area.row, width: area.width,
             height: edgeBandCells(area.height))
  of leBottom:
    let h = edgeBandCells(area.height)
    CellArea(col: area.col, row: area.row + area.height - h,
             width: area.width, height: h)

proc cellsFor*(geom: LayoutGeometry; region: DropRegion): CellArea =
  ## **The hit-test, pointing the other way**: the cells a renderer highlights
  ## for a drop region.
  ##
  ## `DropRegion` carries a path and which part of it and NO extent, precisely
  ## because "a front-end already knows where the node at `path` is: it drew
  ## it". This is that knowledge, and it is the same table `pointerAt` reads —
  ## the band a `drNodeStrip` occupies is `edgeBandCells` deep on both sides of
  ## the conversion, so a cell that hit-tests to `dzLeftEdge` is inside the
  ## rectangle drawn for the `leLeft` strip. The suite asserts that round trip
  ## rather than leaving it to this sentence.
  case region.kind
  of drLayoutStrip:
    geom.stripAreaOf(region.side)
  of drWholeNode:
    geom.dropAreaOfPath(region.path)
  of drNodeStrip:
    stripOf(geom.dropAreaOfPath(region.path), region.side)
  of drTabSlot:
    let strip = geom.tabStripOf(region.path)
    if not strip.found:
      return CellArea()
    # The caret is one cell wide on the strip's own row: an INSERTION POINT
    # between two tabs, not a tab. A highlight covering a whole tab would say
    # "replace this one".
    let caret = tabSlotCaret(strip.tabs, strip.active, region.slot)
    CellArea(col: strip.area.col + min(caret, max(0, strip.area.width - 1)),
             row: strip.area.row, width: 1, height: 1)

proc cellsFor*(geom: LayoutGeometry; target: DropTarget): CellArea =
  ## The cells for a candidate. One line, because a `DropTarget` carries its
  ## own region and there is no second rule.
  geom.cellsFor(target.region)

# ---------------------------------------------------------------------------
# §5 obligation 3: drawing the transient state
# ---------------------------------------------------------------------------

proc stripLabel(strip: DockStrip): string =
  var parts: seq[string] = @[]
  for s in strip.slots:
    parts.add s.title
  parts.join(" ")

proc ghostAreaFor(geom: LayoutGeometry; source: PaneKind;
                  origin: DragOrigin): CellArea =
  ## Where the dragged pane currently is — its own rectangle, its tab's cells,
  ## or its collapsed slot in a dock strip.
  case origin.kind
  of doDock:
    for s in geom.strips:
      if s.edge != origin.dockEdge:
        continue
      for slot in s.slots:
        if slot.pane == source:
          return slot.area
    CellArea()
  of doStack:
    let strip = geom.tabStripOf(origin.stackPath)
    if not strip.found:
      return CellArea()
    let spans = tabSpans(strip.tabs, strip.active)
    if origin.index >= 0 and origin.index < spans.len:
      return CellArea(col: strip.area.col + spans[origin.index].startCol,
                      row: strip.area.row,
                      width: min(spans[origin.index].width,
                                 max(0, strip.area.width -
                                        spans[origin.index].startCol)),
                      height: 1)
    strip.area
  of doRegion:
    geom.boundsOfPath(origin.regionPath)

proc resizeGuideFor(layout: Layout; geom: LayoutGeometry;
                    interaction: Interaction;
                    policy: ProjectionPolicy): CellArea =
  ## Where the divider would sit if the resize committed now.
  ##
  ## Computed by PROJECTING THE PROPOSED LAYOUT rather than by arithmetic on
  ## weights: the guide then shows exactly the edge the drop will produce,
  ## including `distributeCells`'s rounding, instead of a preview that is off
  ## by a cell at some geometries. The proposal is applied to a COPY through
  ## `apply`, so nothing here touches the committed layout.
  let pending = pendingCommand(layout, interaction)
  if pending.isNone:
    return CellArea()
  let outcome = apply(layout, pending.get)
  if outcome.kind != loApplied:
    return CellArea()
  let info = nodeInfoAtPath(layout.tree, interaction.node)
  if info.isNone or info.get.kind != lnPane:
    return CellArea()
  let after = geometryOf(outcome.layout, geom.body, noInteraction(), policy)
  let now = after.regionOfPane(info.get.pane)
  if now.isEmptyArea:
    return CellArea()
  let before = geom.regionOfPane(info.get.pane)
  if before.isEmptyArea:
    return CellArea()
  # The moved edge is the one that is no longer where it was. A pane keeps its
  # origin when it grows to the right or downwards, and moves it otherwise, so
  # comparing both ends and taking the changed one covers all four cases.
  if now.width != before.width:
    let edgeCol = if now.col == before.col: now.col + now.width - 1 else: now.col
    CellArea(col: edgeCol, row: now.row, width: 1, height: now.height)
  elif now.height != before.height:
    let edgeRow = if now.row == before.row: now.row + now.height - 1 else: now.row
    CellArea(col: now.col, row: edgeRow, width: now.width, height: 1)
  else:
    CellArea()

proc decorationsFor*(layout: Layout; geom: LayoutGeometry;
                     interaction: Interaction;
                     policy: ProjectionPolicy = DefaultProjectionPolicy):
    seq[LayoutDecoration] =
  ## Everything a frame draws that is not a pane, **derived from
  ## `Interaction`** and stored by nobody (§5, obligation 3).
  ##
  ## The order is the paint order: strips first (they are chrome), then the
  ## ghost, then the highlighted target over it, then the guide, then the
  ## reveal overlay last because an overlay is by definition on top.
  result = @[]
  for strip in geom.strips:
    result.add LayoutDecoration(kind: ldDockStrip, area: strip.area,
                                label: stripLabel(strip))
  case interaction.kind
  of ikNone:
    discard
  of ikDraggingTab:
    let ghost = ghostAreaFor(geom, interaction.source, interaction.origin)
    if not ghost.isEmptyArea:
      result.add LayoutDecoration(kind: ldDragGhost, area: ghost,
                                  label: $interaction.source)
    if interaction.hover.isSome:
      let target = interaction.hover.get
      let area = geom.cellsFor(target)
      if not area.isEmptyArea:
        result.add LayoutDecoration(kind: ldDropTarget, area: area,
                                    label: $target.kind)
  of ikResizingSplit:
    let guide = resizeGuideFor(layout, geom, interaction, policy)
    if not guide.isEmptyArea:
      result.add LayoutDecoration(kind: ldResizeGuide, area: guide,
                                  label: "resize")
  of ikRevealingDock:
    if not geom.reveal.isEmptyArea:
      result.add LayoutDecoration(kind: ldRevealOverlay, area: geom.reveal,
                                  label: $interaction.pane)

proc glyphFor*(kind: LayoutDecorationKind): string =
  case kind
  of ldDockStrip: DockStripGlyph
  of ldDragGhost: DragGhostGlyph
  of ldDropTarget: DropTargetGlyph
  of ldResizeGuide: ResizeGuideGlyph
  of ldRevealOverlay: RevealOverlayGlyph

proc healWideEdges(g: var StyledGrid; row, left, right: int) =
  ## Make the columns `[left, right)` safe to overwrite one cell at a time.
  ##
  ## `StyledGrid` stores a wide rune in its first column and a zero-width
  ## marker in the second, so a row's cell count is its column count. Writing a
  ## ONE-cell glyph over either half of such a pair on its own would leave the
  ## row a cell short or a cell long — and a row that is not exactly `width`
  ## cells is the defect CTUI-2's cross-tier run found three times in sibling
  ## libraries. So both straddling pairs are blanked before the fill starts: a
  ## wide glyph either survives whole or is replaced whole.
  if left > 0 and g.runeAt(row, left) == "":
    g.paint(row, left - 1, " ")
  if right < g.width and g.runeAt(row, right) == "":
    g.paint(row, right - 1, " ")
    g.paint(row, right, " ")

proc paintDecorations*(g: var StyledGrid;
                       decorations: seq[LayoutDecoration]) =
  ## Composite decorations onto a painted screen, in place.
  ##
  ## **No style**, deliberately: `app/theme/degradation.nim` re-tints a
  ## composited screen by semantic role, so a layer that painted its own
  ## colours would bypass the one place this front-end decides what things look
  ## like. What a decoration carries instead is a GLYPH per kind — which is
  ## also what makes it assertable as text, at Tier 1 and at Tier 2 alike.
  ##
  ## Each decoration fills its rectangle with the kind's glyph and then writes
  ## its label along the first row, so a snapshot says WHAT is highlighted as
  ## well as where.
  for d in decorations:
    if d.area.isEmptyArea:
      continue
    let glyph = glyphFor(d.kind)
    let right = d.area.col + d.area.width
    for row in d.area.row ..< d.area.row + d.area.height:
      if row < 0 or row >= g.height:
        continue
      healWideEdges(g, row, max(0, d.area.col), right)
      for col in max(0, d.area.col) ..< min(g.width, right):
        g.paint(row, col, glyph)
      if row == d.area.row and d.label.len > 0:
        # Clipped to the rectangle, so a label can never widen the decoration
        # it names.
        g.paint(row, d.area.col, fitCells(d.label, d.area.width).strip(
          leading = false))

# ---------------------------------------------------------------------------
# §5 obligation 4: gestures
# ---------------------------------------------------------------------------

proc action(status: LayoutActionStatus; message: string;
            command = none(LayoutCommand);
            problem = none(LayoutProblem)): LayoutAction =
  LayoutAction(status: status, message: message, command: command,
               problem: problem)

proc layout*(b: LayoutBinding): Layout =
  ## The committed layout. Read from the history, so there is no second copy
  ## that could disagree with the undo log.
  b.history.value

proc newLayoutBinding*(layout: Layout; profile: LayoutProfile;
                       focus = paneEditor): LayoutBinding =
  LayoutBinding(history: newLayoutHistory(layout), interaction: noInteraction(),
                profile: profile, focus: focus, userModified: false,
                pressRow: -1, pressCol: -1)

proc newLayoutBinding*(profile: LayoutProfile): LayoutBinding =
  ## A binding on the profile's own default arrangement — the tree
  ## `views/shell.newShellModel` would have built, now with an undo log and a
  ## docked list.
  newLayoutBinding(initLayout(profileLayout(profile)), profile)

proc geometry*(b: LayoutBinding; body: CellArea;
               policy: ProjectionPolicy = DefaultProjectionPolicy):
    LayoutGeometry =
  geometryOf(b.layout, body, b.interaction, policy)

proc dispatch*(b: LayoutBinding; cmd: LayoutCommand): LayoutAction =
  ## Run one command through the undo log. **The only way this module changes a
  ## layout**, so `userModified` and the log cannot come apart from each other
  ## or from the layout.
  let outcome = b.history.dispatch(cmd)
  case outcome.kind
  of loApplied:
    b.userModified = true
    action(lasApplied, $cmd & " applied", some(cmd))
  of loNoOp:
    action(lasNoOp, $cmd & " changed nothing", some(cmd))
  of loRefused:
    action(lasRefused, $cmd & " refused: " & $outcome.problem.kind,
           some(cmd), some(outcome.problem))

proc undoLayout*(b: LayoutBinding): LayoutAction =
  if b.history.undo():
    action(lasApplied, "layout undone")
  else: action(lasNoOp, "nothing to undo")

proc redoLayout*(b: LayoutBinding): LayoutAction =
  if b.history.redo():
    action(lasApplied, "layout redone")
  else: action(lasNoOp, "nothing to redo")

proc beginDrag*(b: LayoutBinding; pane: PaneKind): LayoutAction =
  ## Pick a pane up. Refused — reported, not silent — when it is in neither the
  ## tree nor `docked`.
  let started = beginDragTab(b.layout, pane)
  if started.isNone:
    return action(lasNoGesture, $pane & " is neither placed nor docked")
  b.interaction = started.get
  action(lasPending, "dragging " & $pane)

proc hoverAt*(b: LayoutBinding; geom: LayoutGeometry;
              row, col: int): LayoutAction =
  ## Move the pointer during a drag. Reports what would happen if the button
  ## came up here, which is what the highlight is for.
  if b.interaction.kind != ikDraggingTab:
    return action(lasNoGesture, "no drag in flight")
  let pointer = pointerAt(b.layout, geom, row, col)
  if pointer.isNone:
    b.interaction = b.interaction.hoverAt(
      b.layout, LayoutPointer(path: "", zone: dzCentre))
    return action(lasPending, "over nothing droppable")
  b.interaction = b.interaction.hoverAt(b.layout, pointer.get)
  if b.interaction.hover.isNone:
    return action(lasPending, "no drop target here")
  action(lasPending, "would " & $b.interaction.hover.get)

proc dropDrag*(b: LayoutBinding): LayoutAction =
  ## Let go. `commit` decides whether anything happened, by asking `apply`; the
  ## interaction is cleared either way, because a released button is not a drag
  ## whatever the answer was.
  if b.interaction.kind != ikDraggingTab:
    return action(lasNoGesture, "no drag in flight")
  let cmd = commit(b.layout, b.interaction)
  b.interaction = b.interaction.cancel()
  if cmd.isNone:
    return action(lasNoOp, "the drop changed nothing")
  b.dispatch(cmd.get)

proc cancelGesture*(b: LayoutBinding): LayoutAction =
  ## Abandon whatever is in flight. `cancel` takes no layout, so this cannot
  ## have changed one.
  if b.interaction.kind == ikNone:
    return action(lasNoGesture, "no gesture in flight")
  b.interaction = b.interaction.cancel()
  action(lasCancelled, "gesture cancelled")

proc beginRevealDock*(b: LayoutBinding; pane: PaneKind): LayoutAction =
  let revealed = beginReveal(b.layout, pane)
  if revealed.isNone:
    return action(lasNoGesture, $pane & " is not docked")
  b.interaction = revealed.get
  action(lasPending, "revealing " & $pane)

proc focusedIndexIn(geom: LayoutGeometry; pane: PaneKind): int =
  for i, r in geom.projection.regions:
    if r.pane == pane:
      return i
  -1

proc moveFocus*(b: LayoutBinding; geom: LayoutGeometry;
                dir: FocusDirection): LayoutAction =
  ## `Ctrl+w h/j/k/l`, against this projection.
  ##
  ## Through `motions.paneInDirection` — the SAME geometric rule the focus
  ## chain uses — so the pane `Ctrl+w l` focuses and the pane `:move-pane
  ## right` splits against are the same pane on the same screen.
  let (found, pane) = paneInDirection(
    geom.projection.regions, focusedIndexIn(geom, b.focus), dir)
  if not found:
    return action(lasNoGesture, "no pane to the " & $dir)
  b.focus = pane
  action(lasPending, "focus " & $pane)

# ---------------------------------------------------------------------------
# The mouse. SGR-1006 is decoded by `app/input/mouse.nim`; this maps a decoded
# event onto a gesture.
# ---------------------------------------------------------------------------

proc tabAtCell(b: LayoutBinding; geom: LayoutGeometry;
               row, col: int): Option[PaneKind] =
  ## Which pane's TAB is under the cell, if the cell is on a tab strip.
  let pointer = pointerAt(b.layout, geom, row, col)
  if pointer.isNone or pointer.get.zone != dzTabStrip:
    return none(PaneKind)
  let info = nodeInfoAtPath(b.layout.tree, pointer.get.path)
  if info.isNone or info.get.kind != lnPane:
    return none(PaneKind)
  some(info.get.pane)

proc onMouse*(b: LayoutBinding; geom: LayoutGeometry;
              event: MouseEvent): LayoutAction =
  ## One decoded SGR-1006 report, as a layout gesture.
  ##
  ## THE PROTOCOL GIVES PRESS AND RELEASE AND NOTHING BETWEEN, so a click and a
  ## drag are told apart by WHERE the button came up: released on the cell it
  ## went down on is a click, released anywhere else is a drop. That is the
  ## whole state machine, and it needs no motion reports — which matters,
  ## because this decoder does not request them and a terminal that does not
  ## send them would otherwise make dragging impossible.
  ##
  ##   * press on a tab             -> pick that tab up (a drag begins)
  ##   * press on a bare pane's own
  ##     title row                  -> pick that PANE up. A pane that is not in
  ##                                   a stack has no tab, and without this
  ##                                   rule the commonest shape on screen would
  ##                                   be undraggable
  ##   * press on a dock slot       -> pick that docked pane up
  ##   * press elsewhere in a pane  -> focus it; no gesture
  ##   * release on the press cell  -> a click: activate the tab, or reveal the
  ##                                   docked pane
  ##   * release elsewhere          -> hover there, then drop
  ##   * wheel on a tab strip       -> activate the next / previous tab
  ##
  ## **WHICH DOCK EDGES A MOUSE CAN REACH, recorded rather than implied.** A
  ## drop docks a pane when it lands on a cell OUTSIDE the tree area, and in a
  ## terminal the only such cells are the dock strips themselves and the rows
  ## above and below the body — the header and the status bar. There is no
  ## column to the left of column 0, so with nothing docked yet **the mouse can
  ## dock to the top and the bottom, and `:dock left` / `:dock right` are how
  ## the other two edges are first reached**; after that, dropping onto an
  ## existing left or right strip works like any other. That is a property of
  ## the medium, not a gap in the model: a pixel front-end has margin outside
  ## its layout area and reaches all four the same way.
  ##
  ## That paragraph was written before anything called this routine, and it has
  ## since been MEASURED rather than left as reasoning: `app/tests/
  ## test_layout_command_routing.nim`'s "which dock edges a real drag can reach"
  ## sweeps every cell of an 80x24 screen through `hoverAt` (the set is exactly
  ## `{top, bottom}`), commits four aimed drags through `runtime.handleToken`,
  ## and sweeps again after one `:dock left` (the set becomes
  ## `{bottom, left, top}`).
  case event.button
  of mbWheelUp, mbWheelDown:
    if event.kind != mekPress:
      return action(lasNoGesture, "wheel release ignored")
    let idx = geom.regionIndexAt(event.row, event.col)
    if idx < 0:
      return action(lasNoGesture, "wheel outside the layout")
    let region = geom.projection.regions[idx]
    if region.activeTab < 0 or region.tabs.len == 0 or
       event.row != region.area.row:
      return action(lasNoGesture, "wheel is not over a tab strip")
    let path = geom.pathOfPane(region.pane)
    if path.isNone:
      return action(lasNoGesture, "the stacked pane has no path")
    let stackPath = parentPath(path.get)
    if stackPath.isNone:
      return action(lasNoGesture, "the stack has no path")
    let delta = if event.button == mbWheelDown: 1 else: -1
    let next = region.activeTab + delta
    if next < 0 or next >= region.tabs.len:
      return action(lasNoOp, "already at the end of the tab strip")
    let info = nodeInfoAtPath(b.layout.tree,
                              childPathOf(stackPath.get, next))
    if info.isNone or info.get.kind != lnPane:
      return action(lasNoGesture, "no tab there")
    b.dispatch(cmdActivateTab(info.get.pane))
  of mbLeft:
    if event.kind == mekPress:
      b.pressRow = event.row
      b.pressCol = event.col
      let tab = b.tabAtCell(geom, event.row, event.col)
      if tab.isSome:
        return b.beginDrag(tab.get)
      let strip = geom.stripIndexAt(event.row, event.col)
      if strip >= 0:
        let slot = geom.strips[strip].slotAt(event.row, event.col)
        if slot >= 0:
          return b.beginDrag(geom.strips[strip].slots[slot].pane)
        return action(lasNoGesture, "an empty part of a dock strip")
      let idx = geom.regionIndexAt(event.row, event.col)
      if idx < 0:
        return action(lasNoGesture, "press outside the layout")
      let region = geom.projection.regions[idx]
      b.focus = region.pane
      if region.activeTab < 0 and event.row == region.area.row:
        # A pane with no tab strip is picked up by its own title row.
        return b.beginDrag(region.pane)
      return action(lasNoGesture, "focus " & $b.focus)
    # Release.
    let sameCell = event.row == b.pressRow and event.col == b.pressCol
    b.pressRow = -1
    b.pressCol = -1
    if b.interaction.kind != ikDraggingTab:
      return action(lasNoGesture, "release with no drag in flight")
    let source = b.interaction.source
    if sameCell:
      # A CLICK. Cancel the drag first, so the click's own command is the only
      # thing that reaches `dispatch` — a drag that also committed would push
      # two entries onto one undo log for one gesture.
      discard b.cancelGesture()
      if b.layout.dockedIndex(source) >= 0:
        return b.beginRevealDock(source)
      return b.dispatch(cmdActivateTab(source))
    discard b.hoverAt(geom, event.row, event.col)
    b.dropDrag()
  of mbMiddle, mbRight, mbOther:
    action(lasNoGesture, "this button carries no layout gesture")

# ---------------------------------------------------------------------------
# The keyboard. A terminal user may have no pointer at all, so every gesture
# above has a spelling here.
# ---------------------------------------------------------------------------

type
  LayoutVerb* = enum
    ## The layout command surface, as data.
    ##
    ## SEPARATE FROM `app/commands/interpreter.nim`, deliberately and
    ## structurally: §4.3's sixteen commands are a PUBLISHED table that
    ## `app/tests/test_gdb_command_surface.nim` parses out of
    ## `CodeTracer-TUI.md` and compares row by row, so a seventeenth value in
    ## that enum is a failing test by construction. These are arrangement
    ## commands, they are not in §4.3, and putting them there would either
    ## break that oracle or require editing the published document to describe
    ## something it does not describe.
    lvMoveTab = "move-tab"
    lvMovePane = "move-pane"
    lvMergePane = "merge-pane"
    lvDock = "dock"
    lvUndock = "undock"
    lvReveal = "reveal"
    lvHide = "hide"
    lvResize = "resize"
    lvFocus = "focus"
    lvUndoLayout = "undo-layout"
    lvRedoLayout = "redo-layout"
    lvResetLayout = "reset-layout"

const
  LayoutVerbNames*: array[LayoutVerb, string] = [
    "move-tab", "move-pane", "merge-pane", "dock", "undock", "reveal",
    "hide", "resize", "focus", "undo-layout", "redo-layout", "reset-layout"]
    ## Spelled out rather than read from `$verb`, so the published names and
    ## the enum can be compared as two things in the suite instead of one
    ## thing compared with itself.

proc parseLayoutVerb*(word: string): (bool, LayoutVerb) =
  for v in LayoutVerb:
    if LayoutVerbNames[v] == word:
      return (true, v)
  (false, lvMoveTab)

proc parseEdgeWord(word: string): (bool, LayoutEdge) =
  case word
  of "left": (true, leLeft)
  of "right": (true, leRight)
  of "top", "up": (true, leTop)
  of "bottom", "down": (true, leBottom)
  else: (false, leLeft)

proc parseDirectionWord(word: string): (bool, FocusDirection) =
  case word
  of "left": (true, fdLeft)
  of "right": (true, fdRight)
  of "up", "top": (true, fdUp)
  of "down", "bottom": (true, fdDown)
  else: (false, fdLeft)

proc parsePaneWord(word: string): (bool, PaneKind) =
  for p in PaneKind:
    if $p == word:
      return (true, p)
  (false, paneEditor)

proc tabPositionOf(b: LayoutBinding; pane: PaneKind):
    (bool, string, int, int) =
  ## `(found, stackPath, index, tabCount)` for a pane that is a tab of a stack.
  let path = panePath(b.layout, pane)
  if path.isNone:
    return (false, "", -1, 0)
  let stackPath = parentPath(path.get)
  if stackPath.isNone:
    return (false, "", -1, 0)
  let stack = nodeInfoAtPath(b.layout.tree, stackPath.get)
  if stack.isNone or stack.get.kind != lnStack:
    return (false, "", -1, 0)
  let last = path.get.rfind('/')
  let tail = if last < 0: path.get else: path.get[last + 1 .. ^1]
  var index = -1
  try:
    index = parseInt(tail)
  except ValueError:
    return (false, "", -1, 0)
  (true, stackPath.get, index, stack.get.childCount)

proc moveTabBy(b: LayoutBinding; delta: int; toEnd: bool): LayoutAction =
  ## `:move-tab left|right|first|last` — reorder the focused tab in its stack.
  let (ok, stackPath, index, count) = b.tabPositionOf(b.focus)
  if not ok:
    return action(lasRefused, $b.focus & " is not a tab of a stack")
  # WITHIN ITS OWN STACK the slot range is `0 .. count - 1`, not `0 .. count`:
  # `lcMoveTab` computes its bound from the stack's length AFTER the move, and
  # a same-stack move does not lengthen it. Getting this wrong is an
  # `lpIndexOutOfRange` refusal on the last tab and nowhere else, which is
  # exactly the kind of edge a `:move-tab last` finds first.
  var slot =
    if toEnd: (if delta < 0: 0 else: count - 1)
    else: index + delta
  if slot < 0: slot = 0
  if slot > count - 1: slot = count - 1
  # The anchor must be a DIFFERENT tab: `lcMoveTab` names the destination by a
  # pane IN it, and naming the moved pane itself would ask the model to place
  # something beside where it no longer is.
  var anchor = none(PaneKind)
  for i in 0 ..< count:
    if i == index:
      continue
    let info = nodeInfoAtPath(b.layout.tree, childPathOf(stackPath, i))
    if info.isSome and info.get.kind == lnPane:
      anchor = some(info.get.pane)
      break
  if anchor.isNone:
    return action(lasNoOp,
                  $b.focus & " is the only tab of its stack; there is nothing " &
                  "to reorder it against")
  b.dispatch(cmdMoveTab(b.focus, anchor.get, slot))

proc movePaneTo(b: LayoutBinding; geom: LayoutGeometry;
                dir: FocusDirection): LayoutAction =
  ## `:move-pane <dir>` — split the neighbour in that direction and land the
  ## focused pane on the near side of it. One `lcSplit` with `splitMovesPane`,
  ## which is exactly the command the mouse's edge-drop produces.
  let (found, target) = paneInDirection(
    geom.projection.regions, focusedIndexIn(geom, b.focus), dir)
  if not found:
    return action(lasRefused, "no pane to the " & $dir & " of " & $b.focus)
  let axis = if dir in {fdLeft, fdRight}: saRow else: saColumn
  let side = if dir in {fdLeft, fdUp}: ssBefore else: ssAfter
  b.dispatch(cmdSplitMove(target, b.focus, axis, side))

proc resizeFocusTo(b: LayoutBinding; percent: int): LayoutAction =
  ## `:resize <percent>` — the keyboard's divider drag, through exactly the
  ## machine the mouse would use: `beginResize`, `proposeShare`, `commit`.
  let started = beginResize(b.layout, b.focus)
  if started.isNone:
    return action(lasRefused,
                  $b.focus & " has no divider to move (it is the root, or a " &
                  "tab of a stack)")
  let proposed = started.get.proposeShare(b.layout, float(percent) / 100.0)
  let cmd = commit(b.layout, proposed)
  if cmd.isNone:
    return action(lasNoOp, "the resize changed nothing")
  b.dispatch(cmd.get)

proc resetToProfile*(b: LayoutBinding): LayoutAction =
  ## Throw the user's arrangement away and go back to the profile's default.
  ##
  ## THE EXPLICIT WAY BACK that the freeze rule needs — see the module header.
  ## It resets `userModified`, so the layout starts re-flowing on resize
  ## again, and it starts a NEW history: an undo across a reset would take the
  ## user to a layout the profile no longer produces.
  b.history = newLayoutHistory(initLayout(profileLayout(b.profile)))
  b.interaction = noInteraction()
  b.userModified = false
  action(lasApplied, "layout reset to the " & $b.profile & " profile")

proc runLayoutCommand*(b: LayoutBinding; geom: LayoutGeometry;
                       line: string): LayoutAction =
  ## One typed layout command. **Nothing here is silent**: an unknown word, a
  ## missing argument and a bad one are three different reports, on
  ## `app/commands/interpreter.nim`'s rule.
  var text = line.strip()
  if text.startsWith(":"):
    text = text[1 .. ^1].strip()
  if text.len == 0:
    return action(lasUnknownCommand, "no command")
  let words = text.splitWhitespace()
  let (known, verb) = parseLayoutVerb(words[0])
  if not known:
    return action(lasUnknownCommand,
                  "'" & words[0] & "' is not a layout command")
  let arg = if words.len > 1: words[1] else: ""
  case verb
  of lvMoveTab:
    case arg
    of "": action(lasBadArgument, ":move-tab needs left|right|first|last")
    of "left": b.moveTabBy(-1, false)
    of "right": b.moveTabBy(1, false)
    of "first": b.moveTabBy(-1, true)
    of "last": b.moveTabBy(1, true)
    else: action(lasBadArgument,
                 "'" & arg & "' is not left|right|first|last")
  of lvMovePane:
    let (ok, dir) = parseDirectionWord(arg)
    if not ok:
      return action(lasBadArgument, ":move-pane needs left|right|up|down")
    b.movePaneTo(geom, dir)
  of lvMergePane:
    let (ok, pane) = parsePaneWord(arg)
    if not ok:
      return action(lasBadArgument,
                    ":merge-pane needs the name of a pane, not '" & arg & "'")
    b.dispatch(cmdMergeIntoStack(b.focus, pane))
  of lvDock:
    let (ok, edge) = parseEdgeWord(arg)
    if not ok:
      return action(lasBadArgument, ":dock needs left|right|top|bottom")
    b.dispatch(cmdDock(b.focus, edge))
  of lvUndock:
    if arg.len == 0:
      return b.dispatch(cmdRestoreDocked(b.focus))
    let (ok, pane) = parsePaneWord(arg)
    if not ok:
      return action(lasBadArgument,
                    ":undock's anchor must be a pane, not '" & arg & "'")
    b.dispatch(cmdRestoreDocked(b.focus, some(pane)))
  of lvReveal:
    if arg.len == 0:
      return b.beginRevealDock(b.focus)
    let (ok, pane) = parsePaneWord(arg)
    if not ok:
      return action(lasBadArgument,
                    ":reveal needs the name of a pane, not '" & arg & "'")
    b.beginRevealDock(pane)
  of lvHide:
    b.cancelGesture()
  of lvResize:
    if arg.len == 0:
      return action(lasBadArgument, ":resize needs a percentage")
    var percent = 0
    try:
      percent = parseInt(arg.strip(chars = {'%'}, leading = false))
    except ValueError:
      return action(lasBadArgument, "'" & arg & "' is not a percentage")
    if percent < 1 or percent > 99:
      return action(lasBadArgument,
                    "a share must be between 1 and 99, not " & $percent)
    b.resizeFocusTo(percent)
  of lvFocus:
    let (ok, dir) = parseDirectionWord(arg)
    if not ok:
      return action(lasBadArgument, ":focus needs left|right|up|down")
    b.moveFocus(geom, dir)
  of lvUndoLayout: b.undoLayout()
  of lvRedoLayout: b.redoLayout()
  of lvResetLayout: b.resetToProfile()

# ---------------------------------------------------------------------------
# The responsive-profile decision, and persistence
# ---------------------------------------------------------------------------

proc resize*(b: LayoutBinding; width, height: int): bool =
  ## A new terminal size. Returns whether the arrangement was re-flowed.
  ##
  ## **THE DECISION Layout-ViewModel §8.2 and §8.4 ask for**, implemented: the
  ## profile always tracks the size (the status bar names it, and it is what
  ## `resetToProfile` would restore), but the TREE is rebuilt only while the
  ## user has not modified it. The moment a layout command applies,
  ## `userModified` is set and a resize stops throwing the user's arrangement
  ## away.
  ##
  ## This is the same guard `views/shell.reprofile` already applied to the
  ## ACTIVE TAB, generalised to the whole arrangement and for the same reason:
  ## a reflow that silently reset what the user chose is indistinguishable from
  ## a bug.
  let selected = selectProfile(width, height)
  if selected == b.profile:
    return false
  b.profile = selected
  if b.userModified:
    return false
  b.history = newLayoutHistory(initLayout(profileLayout(selected)))
  b.interaction = noInteraction()
  true

proc saveDocument*(b: LayoutBinding): JsonNode =
  ## The committed layout as a versioned document — tree, docked panes and all.
  ## `revealed` is not in it, because `toJson` omits it (§3.2) and because the
  ## authority on "is this overlay open" is `Interaction`, which is not part of
  ## a `Layout` at all.
  saveLayout(b.layout)

proc restoreDocument*(b: LayoutBinding; doc: JsonNode): LayoutAction =
  ## Adopt a saved arrangement. A decode failure is REPORTED by kind, never
  ## swallowed: `layout_model` raises `LayoutDecodeError` precisely so a
  ## restore that names an unknown pane is a message rather than a blank
  ## region.
  try:
    let restored = restoreLayoutDocument(doc)
    b.history = newLayoutHistory(restored)
    b.interaction = noInteraction()
    b.userModified = true
    action(lasApplied, "layout restored")
  except LayoutDecodeError as e:
    action(lasBadArgument, "the saved layout could not be read: " & e.msg)
