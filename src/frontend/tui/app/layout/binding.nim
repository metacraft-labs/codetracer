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

import std/[json, math, options, strutils]
from std/unicode import runeLen

import headless_app/layout_interaction
import headless_app/layout_model

# PLAT-45: `pmDebug`, for the fold depth `resize` compares.
import codetracer_embed

import ../input/motions
import ../input/mouse
import ../views/header
import ../views/styled_row
import ./profile
import ./project
import ./tab_strip
import ./cells

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
    footerLead*: int
      ## How many cells of the status row precede the bottom labels (the
      ## status bar's file info, `footerLeadCells`).
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
    openDock*: CellArea
      ## PLAT-49 part B (finding 9): where the docked pane shown OPEN
      ## (`DockedPane.open`, the desktop's clicked strip tab) is painted — a
      ## band against its edge that the TREE GIVES UP (`inner` excludes it),
      ## so it is part of the tiled screen, not an overlay. Zero when none.
    openDockPane*: PaneKind
    openDockTitle*: string
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
      ## The thing the user is "carrying": since PLAT-47 a small label with
      ## the dragged pane's name that FOLLOWS THE POINTER (GoldenLayout's drag
      ## proxy), drawn above the drop tint; where no pointer is known (a
      ## keyboard-started drag) it marks the pane's origin as before.
    ldDropTarget = "dropTarget"
      ## The region the drop would OCCUPY (PLAT-47, GoldenLayout's drop
      ## zone): the half of a pane a split would take, the tab strip a join
      ## would enter, a bare pane a join would stack, the edge a dock would
      ## use (`layout_interaction.dropIndicationOf`). Highlighted without
      ## re-checking anything, because `dropTargetsFor` already filtered
      ## through `apply`. Drawn as a TINT of the cells, never over them.
    ldDropCaret = "dropCaret"
      ## For a join, the insertion point in the tab strip: one cell, drawn
      ## as a stronger tint than the strip.
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
    pointerRow*: int
    pointerCol*: int
      ## PLAT-47: where the pointer is during a drag — the press, then every
      ## motion report — so the ghost label follows it. A MEASUREMENT, and so
      ## held here in the terminal's binding, never in the `Interaction`
      ## (PLAT-5's purity law). -1 when no drag is in flight.
    footerLead*: int
      ## The status row's file-info width (`footerLeadCells`), kept current
      ## by the application with every frame it builds, so the bottom
      ## labels' hit-test is where the frame drew them.
    pendingPick*: Option[PaneKind]
      ## PLAT-49: the pane a press on its tab (a lone pane's strip, a dock
      ## label) WOULD pick up. A press alone picks nothing up: the drag
      ## begins only when the pointer has moved `DragThresholdCells` from the
      ## press (`dragThresholdPassed`); a release before that is a click.
    liveResize*: bool
      ## PLAT-51 deliverable 11 (Layout-ViewModel §4.3a): a divider drag
      ## REFLOWS the panes at every pointer position (`presentedLayout`), the
      ## default; false draws the resize guide and reflows on release
      ## (`--live-resize=off`, `:set live-resize off`, the persisted
      ## preference). Either way the drag commits ONCE, on release.
    dragLayout*: Layout
      ## PLAT-51: during a tab drag, the arrangement WITHOUT the dragged pane
      ## (`layout_interaction.dragLayoutFor`) — GoldenLayout's `DragProxy`
      ## takes the item out before it measures, so the frame and the
      ## hit-test are this. A nil tree outside a drag.
    glState*: GlDragState
      ## PLAT-51: GoldenLayout's state between two pointer samples of a drag
      ## (each stack's segment and index, the placeholder, the last valid
      ## area) — a MEASUREMENT's consequence, so held here, never in the
      ## `Interaction` (PLAT-5's purity law).
    glPaths*: seq[string]
      ## The stack paths (in `dragLayout`) `glState` indexes.
    pressWasRevealing*: bool
    pressRevealedPane*: PaneKind
      ## PLAT-48: the pane that was REVEALED when the button went down. A
      ## press on a strip label starts a drag (which replaces the reveal), so
      ## the release needs this to tell "a second click on the revealed
      ## pane's label" (hide it) from a first click (reveal it).

const
  DockStripThickness* = 1
    ## One row (top/bottom) or one column (left/right). A terminal's body is
    ## measured in a few dozen cells and a two-cell strip on two edges costs a
    ## Compact profile four of them; one cell is enough for a readable
    ## collapsed tab and is what §3.1's desktop strip degrades to.

  DragThresholdCols* = 2
  DragThresholdRows* = 1
    ## PLAT-49 (the user, 2026-10-01): how far the pointer must move from a
    ## press on a tab or a divider before a DRAG begins — two columns or one
    ## row (a cell is about twice as tall as it is wide, so the two are about
    ## the same distance). Less than that and the press is a click: a plain
    ## click never picks anything up and never reports a drag.

  RevealShareDenominator* = 3
    ## A revealed dock overlay takes a third of the inner area's extent on its
    ## axis, clamped to at least one cell. A third rather than a half because
    ## the point of a peek is that the arrangement behind it is still readable.

  DockStripGlyph* = " "
    ## PLAT-48: a dock strip's FILLER is blank. The shell paints a strip as the
    ## desktop's footer does — each docked pane's padded label, in strip
    ## order, on the strip's surface (`shell.paintDockStrips`) — so every
    ## cell no label covers is a blank, where it was a `·` until PLAT-48.
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

proc stripAreaFor(body: CellArea; edge: LayoutEdge; left, right: int;
                  footerLead = 0): CellArea =
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
    # PLAT-49 part B (finding 9): THE BOTTOM STRIP IS THE STATUS BAR'S ROW —
    # the row right under the body — as the desktop renders its bottom labels
    # INSIDE the status bar (Auto-Hide-Panes.md §3.1, "Bottom strip
    # integration"). It takes no row from the body. It starts after the
    # status bar's FILE INFO (`footerLead` cells, `footerLeadCells`): the
    # desktop's status bar opens with the file's language and encoding and
    # its labels follow them.
    let lead = max(0, min(footerLead, body.width - left - right))
    CellArea(col: body.col + left + lead, row: body.row + body.height,
             width: body.width - left - right - lead,
             height: DockStripThickness)

proc slotExtent*(edge: LayoutEdge; title: string): int =
  ## How many cells one docked pane's LABEL takes along its strip (PLAT-48):
  ## a top or bottom strip's label is a tab — the title padded one cell each
  ## side, as the desktop's footer strip draws BUILD, PROBLEMS, …; a left or
  ## right strip's reads DOWNWARDS, one character per row, with one row of
  ## space after it.
  if edge in {leTop, leBottom}: cellWidthOf(title) + 2
  else: title.runeLen + 1

proc slotAreas(strip: CellArea; edge: LayoutEdge;
               titles: seq[string]): seq[CellArea] =
  ## The strip's labels, one slot each, packed from the strip's start as the
  ## desktop's strip packs its tabs. The rest of the strip is the strip, not
  ## a slot: a press there reveals nothing. A label that does not fit whole
  ## is clipped to the strip; one with no cell left gets an empty slot (it is
  ## still docked, and `:reveal` still reaches it).
  ##
  ## Until PLAT-48 the strip was divided EQUALLY among its panes and every
  ## title was written along its first row — so a left or right strip showed
  ## one character of one title.
  result = @[]
  if titles.len == 0 or strip.isEmptyArea:
    return
  let horizontal = edge in {leTop, leBottom}
  let stop = if horizontal: strip.col + strip.width
             else: strip.row + strip.height
  var cursor = if horizontal: strip.col else: strip.row
  for t in titles:
    let s = max(0, min(slotExtent(edge, t), stop - cursor))
    if horizontal:
      result.add CellArea(col: cursor, row: strip.row, width: s,
                          height: (if s > 0: strip.height else: 0))
    else:
      result.add CellArea(col: strip.col, row: cursor,
                          width: (if s > 0: strip.width else: 0), height: s)
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

const
  DockedOpenSharePercent* = 21
    ## PLAT-49 part B: how much of the arrangement's extent a docked pane
    ## shown OPEN takes on its axis — the desktop's, measured: its docked
    ## bottom panel is 280 px of a 1334 px layout (21%,
    ## `plat49-panes-capture.spec.ts`; `auto_hide.styl`'s default height).

proc openDockAreaFor(inner: CellArea; edge: LayoutEdge): CellArea =
  ## The band a docked pane shown open takes against its edge.
  if inner.isEmptyArea:
    return CellArea()
  let h = max(2, inner.height * DockedOpenSharePercent div 100)
  let w = max(2, inner.width * DockedOpenSharePercent div 100)
  case edge
  of leLeft: CellArea(col: inner.col, row: inner.row, width: w,
                      height: inner.height)
  of leRight: CellArea(col: inner.col + inner.width - w, row: inner.row,
                       width: w, height: inner.height)
  of leTop: CellArea(col: inner.col, row: inner.row, width: inner.width,
                     height: h)
  of leBottom: CellArea(col: inner.col, row: inner.row + inner.height - h,
                        width: inner.width, height: h)

proc footerLeadCells*(fileInfo: string): int =
  ## How many cells of the status row the FILE INFO takes before the bottom
  ## labels (`headless_app/footer_info`): a cell, the info, two cells; none
  ## without a file.
  if fileInfo.len == 0: 0 else: 1 + cellWidthOf(fileInfo) + 2

proc geometryOf*(layout: Layout; body: CellArea;
                 interaction: Interaction = noInteraction();
                 policy: ProjectionPolicy = DefaultProjectionPolicy;
                 footerLead = 0):
    LayoutGeometry =
  ## Where everything is, for one frame.
  ##
  ## THE DOCK STRIPS COME OUT OF THE BODY FIRST, and the tree is projected into
  ## what is left. That ordering is what keeps CTUI-3's invariant true and
  ## meaningful at the same time: the projection is still total and pairwise
  ## disjoint over `inner`, and `inner` plus the strips is `body` exactly, so
  ## nothing on screen belongs to nobody.
  result = LayoutGeometry(body: body, footerLead: footerLead,
                          inner: body, strips: @[], paths: @[],
                          revealing: false, revealPane: PaneKind.low,
                          reveal: CellArea())
  var left = 0
  var rightW = 0
  for edge in [leLeft, leRight]:
    if layout.dockedAt(edge).len > 0:
      if edge == leLeft: left = DockStripThickness else: rightW = DockStripThickness
  var top = 0
  var bottom = 0
  if layout.dockedAt(leTop).len > 0:
    top = DockStripThickness
  # The bottom strip is on the status row (`stripAreaFor`): the body keeps
  # all its rows.

  for edge in [leLeft, leRight, leTop, leBottom]:
    let docked = layout.dockedAt(edge)
    if docked.len == 0:
      continue
    let area = stripAreaFor(body, edge, left, rightW, footerLead)
    var strip = DockStrip(edge: edge, area: area, slots: @[])
    var titles: seq[string] = @[]
    for d in docked:
      titles.add(if d.title.len > 0: d.title else: terminalPaneName(d.pane))
    let areas = slotAreas(area, edge, titles)
    for i, d in docked:
      strip.slots.add DockStripSlot(
        pane: d.pane, title: titles[i],
        order: d.order,
        area: (if i < areas.len: areas[i] else: CellArea()))
    if edge == leBottom:
      # On the status row the strip is its LABELS and no more: the rest of
      # the row is the status bar's (`shell.shellScreen`).
      var used = 0
      for a in areas:
        used += a.width
      strip.area.width = min(strip.area.width, used)
    result.strips.add strip

  result.inner = CellArea(col: body.col + left, row: body.row + top,
                          width: max(0, body.width - left - rightW),
                          height: max(0, body.height - top - bottom))
  # PLAT-49 part B: A DOCKED PANE SHOWN OPEN TAKES ITS BAND OUT OF THE TREE'S
  # AREA, as the desktop's docked panel resizes GoldenLayout: the band against
  # its edge (a third of that axis, the reveal's share), and the tree is
  # projected into what is left — tiled, never over it.
  let opened = layout.openDocked
  if opened.isSome:
    let band = openDockAreaFor(result.inner, opened.get.edge)
    if not band.isEmptyArea and
       (if opened.get.edge in {leTop, leBottom}: band.height < result.inner.height
        else: band.width < result.inner.width):
      result.openDock = band
      result.openDockPane = opened.get.pane
      result.openDockTitle =
        if opened.get.title.len > 0: opened.get.title
        else: terminalPaneName(opened.get.pane)
      case opened.get.edge
      of leLeft:
        result.inner.col += band.width
        result.inner.width -= band.width
      of leRight:
        result.inner.width -= band.width
      of leTop:
        result.inner.row += band.height
        result.inner.height -= band.height
      of leBottom:
        result.inner.height -= band.height
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
  # PLAT-51: A BARE PANE'S STRIP is a one-tab header (GoldenLayout wraps
  # every component in a stack), so a join onto it has a strip and a slot.
  for i, entry in geom.paths:
    if entry[1] == stackPath:
      let r = geom.projection.regions[i]
      if r.activeTab < 0 and r.area.row == bounds.row:
        return TabStripGeometry(
          found: true, tabs: @[terminalPaneName(r.pane)], active: 0,
          area: CellArea(col: bounds.col, row: bounds.row,
                         width: bounds.width, height: 1))

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
    # PLAT-49: EVERY pane's first row is a strip — a stack's tabs or a lone
    # pane's one tab — so a bare pane's drop body starts below it too, as a
    # GoldenLayout stack's content area starts below its header.
    if region.area.row == bounds.row and bounds.height > 1:
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

const
  LoneEditorLabelCells* = 24
    ## PLAT-50: how many cells of a lone editor's strip are its tab. The
    ## terminal names a lone editor's tab after its FILE (`shell.paintPane`),
    ## which the binding does not know; the file names this front-end shows
    ## fit here, and past it the strip is the divider above (`dividerAt`).

type
  GoldenHit* = object
    ## PLAT-51 deliverable 10 (Layout-ViewModel §4.2.2): the terminal's frame
    ## as GoldenLayout would measure it, in PIXELS — every stack (a stack, or
    ## a bare pane: GoldenLayout wraps each component in one) as its element,
    ## its header (the strip row), its content (the rows below) and its tabs,
    ## through the measured cell size — so the ported `golden_layout_hit`
    ## decides on the terminal exactly as it decides on the desktop.
    geom*: GlGeometry
    areas*: seq[GlArea]
    paths*: seq[string]
      ## Per stack, its path in the layout the frame drew.
    regions*: seq[int]
      ## Per stack, its projection region.
    cellW*, cellH*: float
    placeholderCells*: int
      ## The tab-drop placeholder's width in cells (`placeholderCellsFor`).

proc placeholderCellsFor*(cellW: float): int =
  ## GoldenLayout's 100 px placeholder (`GlPlaceholderPx`) in this terminal's
  ## cells: at least one.
  if cellW <= 0.0: 1
  else: max(1, int(GlPlaceholderPx / cellW + 0.5))

proc pxOf(a: CellArea; cw, ch: float): GlRect =
  glRect(float(a.col) * cw, float(a.row) * ch, float(a.width) * cw,
         float(a.height) * ch)

proc cellsOfPx*(r: GlRect; cw, ch: float): CellArea =
  ## The cells whose CENTRES lie in `r` (`x1 <= centre < x2`) — the cells a
  ## cell-reporting terminal can point into it with.
  if cw <= 0.0 or ch <= 0.0 or r.width <= 0.0 or r.height <= 0.0:
    return CellArea()
  let c0 = int(ceil(r.x1 / cw - 0.5))
  let c1 = int(ceil(r.x2 / cw - 0.5))
  let r0 = int(ceil(r.y1 / ch - 0.5))
  let r1 = int(ceil(r.y2 / ch - 0.5))
  CellArea(col: c0, row: r0, width: max(0, c1 - c0), height: max(0, r1 - r0))

proc loneLabelCells(pane: PaneKind): int =
  ## How wide a lone pane's one tab is (`onStripLabel`'s answer).
  if pane == paneEditor: LoneEditorLabelCells
  else: textCells(" " & terminalPaneName(pane) & " ")

proc regionIndexOfPane(geom: LayoutGeometry; pane: PaneKind): int =
  for i, r in geom.projection.regions:
    if r.pane == pane:
      return i
  -1

proc boxOfRegion*(geom: LayoutGeometry; a: CellArea): CellArea =
  ## A region minus the divider column on its right (`shell.paneFrame`): the
  ## pane's own box, GoldenLayout's stack element.
  let flushRight = a.col + a.width >= geom.inner.col + geom.inner.width
  CellArea(col: a.col, row: a.row,
           width: (if flushRight: a.width else: max(0, a.width - 1)),
           height: a.height)

proc goldenHitOf*(layout: Layout; geom: LayoutGeometry;
                  m: MouseMetrics = mouseMetrics()): GoldenHit =
  ## The frame `geom` (projected from `layout`) as GoldenLayout's geometry.
  let cw = m.cellW
  let ch = m.cellH
  result = GoldenHit(cellW: cw, cellH: ch,
                     placeholderCells: placeholderCellsFor(cw))
  result.geom = GlGeometry(
    ground: pxOf(geom.inner, cw, ch),
    rootIsStack: not layout.tree.isNil and
                 layout.tree.kind in {lnStack, lnPane},
    placeholderPx: float(result.placeholderCells + TabGapCells) * cw)
  for path in goldenStackPaths(layout):
    var idx = -1
    for entry in geom.paths:
      let child =
        if path.len == 0: entry[1].len > 0 and '/' notin entry[1]
        else: entry[1].startsWith(path & "/") and
              entry[1].count('/') == path.count('/') + 1
      if entry[1] == path or child:
        idx = geom.regionIndexOfPane(entry[0])
        break
    if idx < 0:
      continue
    let region = geom.projection.regions[idx]
    let box = geom.boxOfRegion(region.area)
    if box.isEmptyArea:
      continue
    var st = GlStack(element: pxOf(box, cw, ch),
                     header: pxOf(CellArea(col: box.col, row: box.row,
                                           width: box.width, height: 1),
                                  cw, ch),
                     content: pxOf(CellArea(col: box.col, row: box.row + 1,
                                            width: box.width,
                                            height: max(0, box.height - 1)),
                                   cw, ch))
    if region.activeTab >= 0 and region.tabs.len > 0:
      for span in tabSpans(region.tabs, region.activeTab):
        st.tabs.add pxOf(CellArea(col: box.col + span.startCol, row: box.row,
                                  width: span.width, height: 1), cw, ch)
    else:
      st.tabs.add pxOf(CellArea(col: box.col, row: box.row,
                                width: min(box.width,
                                           loneLabelCells(region.pane)),
                                height: 1), cw, ch)
    result.geom.stacks.add st
    result.paths.add path
    result.regions.add idx
  result.areas = glItemAreas(result.geom)

proc pointerOfDrop(layout: Layout; drop: GoldenDrop): Option[LayoutPointer] =
  ## A decision of the port, in the model's pointer vocabulary (a node path
  ## and a zone) — for the callers that ask about a cell outside any drag.
  case drop.kind
  of gdNone:
    none(LayoutPointer)
  of gdRootSide:
    some(LayoutPointer(path: "", zone: rootZoneOf(drop.edge)))
  of gdSplit, gdHeader, gdCentre:
    let info = nodeInfoAtPath(layout.tree, drop.stackPath)
    if info.isNone:
      return none(LayoutPointer)
    let isStack = info.get.kind == lnStack and info.get.childCount > 0
    let active = if isStack: childPathOf(drop.stackPath, info.get.activeIndex)
                 else: drop.stackPath
    case drop.kind
    of gdSplit:
      let zone = case drop.edge
        of leLeft: dzLeftEdge
        of leRight: dzRightEdge
        of leTop: dzTopEdge
        of leBottom: dzBottomEdge
      some(LayoutPointer(path: active, zone: zone))
    of gdHeader:
      if isStack and drop.index < info.get.childCount:
        some(LayoutPointer(path: childPathOf(drop.stackPath, drop.index),
                           zone: dzTabStrip))
      else:
        some(LayoutPointer(path: active, zone: dzCentre))
    else:
      some(LayoutPointer(path: active, zone: dzCentre))

proc pointerAtPx*(layout: Layout; geom: LayoutGeometry; px, py: float;
                  m: MouseMetrics = mouseMetrics()): Option[LayoutPointer] =
  ## **The hit-test, one sample**: GoldenLayout's decision at pixel
  ## `(px, py)` over the frame `geom`, from a fresh drag (no earlier sample),
  ## as a `LayoutPointer`. A pointer outside the layout is constrained onto
  ## its edge first (`constrainDragToContainer`), so past the body it is the
  ## ground's band — a ROOT split — and never a dock: docking is on the
  ## menus and `:dock` (§4.2.2), as on the desktop.
  let hit = goldenHitOf(layout, geom, m)
  if hit.geom.stacks.len == 0:
    return none(LayoutPointer)
  var state = glDragState(hit.geom)
  let (cx, cy) = glClamp(hit.geom, px, py)
  let d = glPointerStep(hit.geom, hit.areas, state, cx, cy, NativeCentreShare)
  pointerOfDrop(layout, goldenDropOf(d, hit.paths))

proc pointerAt*(layout: Layout; geom: LayoutGeometry;
                row, col: int): Option[LayoutPointer] =
  ## `pointerAtPx` at the CENTRE of cell `(row, col)` through the measured
  ## cell size — what a terminal without SGR-pixel reports points at.
  let m = mouseMetrics()
  pointerAtPx(layout, geom, (float(col) + 0.5) * m.cellW,
              (float(row) + 0.5) * m.cellH, m)

proc rootBandAreaOf*(geom: LayoutGeometry; side: LayoutEdge): CellArea =
  ## GoldenLayout's ground side area along `side` (`createSideAreas`' 50 px
  ## band inside the tree's area) in cells: the cells whose centres it holds,
  ## at least one deep — the cells a root split's indication tints.
  let m = mouseMetrics()
  let ground = pxOf(geom.inner, m.cellW, m.cellH)
  if geom.inner.isEmptyArea:
    return CellArea()
  let wanted = case side
    of leTop: gsTop
    of leLeft: gsLeft
    of leBottom: gsBottom
    of leRight: gsRight
  for a in glSideAreas(ground):
    if a.side == wanted:
      var c = cellsOfPx(a.rect, m.cellW, m.cellH)
      if side in {leLeft, leRight} and c.width == 0:
        c.width = 1
        if side == leRight: c.col = geom.inner.col + geom.inner.width - 1
      if side in {leTop, leBottom} and c.height == 0:
        c.height = 1
        if side == leBottom: c.row = geom.inner.row + geom.inner.height - 1
      return c
  CellArea()

# ---------------------------------------------------------------------------
# §5 obligation 2, second direction: `DropRegion` -> CELLS
# ---------------------------------------------------------------------------

proc cellsFor*(geom: LayoutGeometry; region: DropRegion): CellArea =
  ## **The hit-test, pointing the other way**: the cells a renderer highlights
  ## for a drop region.
  ##
  ## `DropRegion` carries a path and which part of it and NO extent, precisely
  ## because "a front-end already knows where the node at `path` is: it drew
  ## it". This is that knowledge, and it is the same table `pointerAt` reads —
  ## the band a `drNodeStrip` occupies is GoldenLayout's hover area for that
  ## segment (`golden_layout_hit.glStackAreas`) on both sides of the
  ## conversion, so a cell that hit-tests to `dzLeftEdge` is inside the
  ## rectangle drawn for the `leLeft` strip. The suite asserts that round trip
  ## rather than leaving it to this sentence.
  case region.kind
  of drLayoutStrip:
    geom.stripAreaOf(region.side)
  of drRootBand:
    geom.rootBandAreaOf(region.side)
  of drWholeNode:
    geom.dropAreaOfPath(region.path)
  of drNodeStrip:
    # GoldenLayout's HOVER area for that segment of the pane's stack, in the
    # cells whose centres it holds (PLAT-51; the user's centre is not cut
    # out of top and bottom here — a rectangle cannot hold the hole).
    let m = mouseMetrics()
    let bounds = geom.boundsOfPath(region.path)
    let body = geom.dropAreaOfPath(region.path)
    if bounds.isEmptyArea or body.isEmptyArea:
      return CellArea()
    let box = geom.boxOfRegion(bounds)
    let st = GlStack(element: pxOf(box, m.cellW, m.cellH),
                     header: pxOf(CellArea(col: box.col, row: box.row,
                                           width: box.width, height: 1),
                                  m.cellW, m.cellH),
                     content: pxOf(CellArea(col: box.col, row: body.row,
                                            width: box.width,
                                            height: body.height),
                                   m.cellW, m.cellH))
    let wanted = case region.side
      of leLeft: segLeft
      of leRight: segRight
      of leTop: segTop
      of leBottom: segBottom
    for a in glStackAreas(st):
      if a.segment == wanted:
        return cellsOfPx(a.hover, m.cellW, m.cellH)
    CellArea()
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
# PLAT-47 deliverable 6: the drop indication, as cells
# ---------------------------------------------------------------------------

proc halfOf(area: CellArea; side: LayoutEdge): CellArea =
  ## The half of `area` on `side` — what a split's new pane would take. The
  ## odd cell of an odd extent goes to the side named (a 9-column pane's left
  ## half is 5 wide), so a one-cell pane still shows a one-cell half.
  if area.isEmptyArea:
    return CellArea()
  case side
  of leLeft:
    CellArea(col: area.col, row: area.row, width: (area.width + 1) div 2,
             height: area.height)
  of leRight:
    let w = (area.width + 1) div 2
    CellArea(col: area.col + area.width - w, row: area.row, width: w,
             height: area.height)
  of leTop:
    CellArea(col: area.col, row: area.row, width: area.width,
             height: (area.height + 1) div 2)
  of leBottom:
    let h = (area.height + 1) div 2
    CellArea(col: area.col, row: area.row + area.height - h,
             width: area.width, height: h)

proc dropIndicationCells*(geom: LayoutGeometry; ind: DropIndication;
                          placeholderCells = 0):
    tuple[tint, caret: CellArea] =
  ## **The drop indication, resolved against the terminal's geometry**: the
  ## cells the drop would occupy (`tint`) and, for a join, the insertion caret
  ## on the tab strip (`caret`). The one place the terminal turns
  ## `dropIndicationOf`'s logical value into cells, as GoldenLayout sizes its
  ## `lm_dropTargetIndicator`:
  ##
  ##   * a split tints the HALF of the target pane on the drop's side (the
  ##     pane's own rectangle below its tab strip, `dropAreaOfPath`);
  ##   * a join tints the stack's whole tab strip and marks the insertion
  ##     point — the column `tabSlotCaret` gives the slot — with a caret;
  ##   * a join onto a bare pane tints the whole pane;
  ##   * a dock tints the strip along that layout edge (`stripAreaOf`).
  case ind.kind
  of diNone:
    (tint: CellArea(), caret: CellArea())
  of diSplitHalf:
    (tint: halfOf(geom.dropAreaOfPath(ind.path), ind.side), caret: CellArea())
  of diWholeNode:
    (tint: geom.dropAreaOfPath(ind.path), caret: CellArea())
  of diLayoutEdge:
    (tint: geom.stripAreaOf(ind.side), caret: CellArea())
  of diRootBand:
    # GoldenLayout highlights its ground side area itself.
    (tint: geom.rootBandAreaOf(ind.side), caret: CellArea())
  of diTabSlot:
    let strip = geom.tabStripOf(ind.path)
    if not strip.found:
      (tint: CellArea(), caret: CellArea())
    else:
      # PLAT-51: with GoldenLayout's placeholder open in the strip, the caret
      # IS the placeholder — the gap the tabs moved apart for, where the tab
      # would land.
      let spans = tabSpans(strip.tabs, strip.active)
      let at =
        if placeholderCells > 0 and spans.len > 0 and ind.slot >= spans.len:
          spans[^1].startCol + spans[^1].width + TabGapCells
        else: tabSlotCaret(strip.tabs, strip.active, ind.slot)
      let col = strip.area.col + min(at, max(0, strip.area.width - 1))
      (tint: strip.area,
       caret: CellArea(col: col, row: strip.area.row,
                       width: max(1, min(placeholderCells,
                                         strip.area.col + strip.area.width -
                                           col)),
                       height: 1))

proc ghostLabelFor*(source: PaneKind): string =
  ## The dragged pane's name as the ghost shows it, padded like a tab.
  " " & terminalPaneName(source) & " "

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
  ##
  ## The resized node is measured by its PATH (`boundsOfPath`), not as a pane,
  ## so a divider drag between two stacks or two nested rows
  ## (`beginResizeDivider`) draws its guide exactly as a pane resize does. A
  ## weight change never restructures the tree, so the path names the same
  ## node in the proposed layout.
  let pending = pendingCommand(layout, interaction)
  if pending.isNone:
    return CellArea()
  let outcome = apply(layout, pending.get)
  if outcome.kind != loApplied:
    return CellArea()
  let info = nodeInfoAtPath(layout.tree, interaction.node)
  if info.isNone:
    return CellArea()
  let after = geometryOf(outcome.layout, geom.body, noInteraction(), policy,
                         geom.footerLead)
  let now = after.boundsOfPath(interaction.node)
  if now.isEmptyArea:
    return CellArea()
  let before = geom.boundsOfPath(interaction.node)
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
                     policy: ProjectionPolicy = DefaultProjectionPolicy;
                     pointerRow = -1; pointerCol = -1;
                     placeholderCells = 0):
    seq[LayoutDecoration] =
  ## Everything a frame draws that is not a pane, **derived from
  ## `Interaction`** and stored by nobody (§5, obligation 3) — plus, for a
  ## drag, the pointer's cell (`pointerRow` / `pointerCol`, the binding's
  ## measurement), which is where the ghost label goes.
  ##
  ## The order is the paint order: strips first (they are chrome), then the
  ## drop tint and its caret, then the ghost over them, then the guide, then
  ## the reveal overlay last because an overlay is by definition on top.
  result = @[]
  for strip in geom.strips:
    result.add LayoutDecoration(kind: ldDockStrip, area: strip.area,
                                label: stripLabel(strip))
  case interaction.kind
  of ikNone:
    discard
  of ikDraggingTab:
    let indication = dropIndicationOf(interaction)
    let cells = geom.dropIndicationCells(indication, placeholderCells)
    if not cells.tint.isEmptyArea:
      result.add LayoutDecoration(kind: ldDropTarget, area: cells.tint,
                                  label: $indication.kind)
    if not cells.caret.isEmptyArea:
      result.add LayoutDecoration(kind: ldDropCaret, area: cells.caret,
                                  label: "slot " & $indication.slot)
    let label = ghostLabelFor(interaction.source)
    if pointerRow >= 0 and pointerCol >= 0:
      # GoldenLayout's drag proxy: beside the pointer, not under it, so the
      # cell being pointed at stays visible.
      let w = cellWidthOf(label)
      let col = max(0, min(pointerCol + 1, geom.body.col + geom.body.width - w))
      result.add LayoutDecoration(kind: ldDragGhost,
                                  area: CellArea(col: col, row: pointerRow,
                                                 width: w, height: 1),
                                  label: label)
    else:
      let ghost = ghostAreaFor(geom, interaction.source, interaction.origin)
      if not ghost.isEmptyArea:
        result.add LayoutDecoration(kind: ldDragGhost, area: ghost,
                                    label: $interaction.source)
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
  of ldDropCaret: DropTargetGlyph
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

const OverlayDecorations* = {ldDropTarget, ldDropCaret, ldDragGhost}
  ## The decorations a frame carries as OVERLAYS (PLAT-47): the drop tint and
  ## caret re-colour the composited cells, the ghost is a label above them.

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
    if d.kind in OverlayDecorations:
      # PLAT-47: drawn by the compositor OVER the finished frame
      # (`frameOverlaysOf`), not into it — a tint keeps the glyphs under it,
      # and the ghost is above the tint.
      continue
    if d.kind in {ldDockStrip, ldRevealOverlay}:
      # PLAT-48: a strip is its labels on the tab-strip surface
      # (`views/shell.paintDockStrips`) — colour, no `·` fill — and a
      # revealed dock is the docked PANE ITSELF painted over the body
      # (`views/shell.paintRevealedPane`), not a `▒` fill with its name.
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
                pressRow: -1, pressCol: -1, pointerRow: -1, pointerCol: -1,
                liveResize: true)

proc newLayoutBinding*(profile: LayoutProfile): LayoutBinding =
  ## A binding on the profile's own default arrangement — the tree
  ## `views/shell.newShellModel` would have built, now with an undo log and a
  ## docked list.
  newLayoutBinding(profileLayoutValue(profile), profile)

proc presentedLayout*(b: LayoutBinding): Layout =
  ## The arrangement a frame DRAWS — and the one the pointer is hit-tested
  ## against, so the two cannot disagree:
  ##
  ##   * during a tab drag, the layout without the dragged pane
  ##     (`dragLayout`, GoldenLayout's `DragProxy`);
  ##   * during a divider drag with live resize on, the committed layout with
  ##     the interaction's PROPOSED weights in place (`pendingCommand`
  ##     applied to a copy, Layout-ViewModel §4.3a) — every pane re-laid-out
  ##     at its proposed size while the committed layout does not move;
  ##   * otherwise the committed layout.
  case b.interaction.kind
  of ikDraggingTab:
    if not b.dragLayout.tree.isNil: b.dragLayout else: b.layout
  of ikResizingSplit:
    if b.liveResize and b.interaction.divider.isSome:
      let cmd = pendingCommand(b.layout, b.interaction)
      if cmd.isSome:
        let o = apply(b.layout, cmd.get)
        if o.kind == loApplied:
          return o.layout
    b.layout
  else:
    b.layout

proc geometry*(b: LayoutBinding; body: CellArea;
               policy: ProjectionPolicy = DefaultProjectionPolicy):
    LayoutGeometry =
  geometryOf(b.presentedLayout, body, b.interaction, policy, b.footerLead)

proc placeholderOf*(b: LayoutBinding): tuple[found: bool; stackPath: string;
                                             index: int; cells: int] =
  ## PLAT-51: where GoldenLayout's tab-drop PLACEHOLDER is during a drag —
  ## the stack (its path in the drawn layout), the tab it sits before, and
  ## how many cells it is wide. The frame opens that gap in the strip (the
  ## tabs after it move right), exactly as GoldenLayout's strip does.
  if b.interaction.kind != ikDraggingTab or
     b.glState.placeholderStack < 0 or
     b.glState.placeholderStack >= b.glPaths.len:
    return (false, "", -1, 0)
  (true, b.glPaths[b.glState.placeholderStack], b.glState.placeholderIndex,
   placeholderCellsFor(mouseMetrics().cellW))

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
  # GoldenLayout's `DragProxy`: the item leaves its parent before anything is
  # measured — the frame closes up around where it was.
  b.dragLayout = dragLayoutFor(b.layout, pane)
  b.glState = GlDragState(placeholderStack: -1, placeholderIndex: -1,
                          lastValid: -1)
  b.glPaths = @[]
  action(lasPending, "dragging " & $pane)

proc hoverAtPx*(b: LayoutBinding; geom: LayoutGeometry;
                px, py: float): LayoutAction =
  ## Move the pointer during a drag to pixel `(px, py)` — GoldenLayout's
  ## `setDropPosition`, ported (Layout-ViewModel §4.2.2): constrained onto
  ## the layout, `getArea`, the stack's segment or header index (and the
  ## placeholder), carried from the previous sample; a pointer over no area
  ## (a divider) keeps the last valid one. `geom` is the frame being drawn,
  ## which during a drag is `dragLayout`'s. Reports what a release here would
  ## do, which is what the highlight is for.
  if b.interaction.kind != ikDraggingTab:
    return action(lasNoGesture, "no drag in flight")
  let shown = b.presentedLayout
  # THE FRAME BEING DRAWN — re-derived here rather than trusted from the
  # caller, whose geometry may predate the drag (the motion that crossed the
  # threshold is hit-tested on the arrangement the drag just produced).
  let frame = geometryOf(shown, geom.body, b.interaction,
                         DefaultProjectionPolicy, geom.footerLead)
  let hit = goldenHitOf(shown, frame)
  if hit.paths != b.glPaths or b.glState.stacks.len != hit.geom.stacks.len:
    b.glState = glDragState(hit.geom)
    b.glPaths = hit.paths
  let (cx, cy) = glClamp(hit.geom, px, py)
  let d = glPointerStep(hit.geom, hit.areas, b.glState, cx, cy,
                        NativeCentreShare)
  b.interaction = b.interaction.hoverGolden(b.layout, shown,
                                            goldenDropOf(d, hit.paths))
  if not d.found:
    return action(lasPending, "over nothing droppable")
  if b.interaction.hover.isNone:
    return action(lasPending, "no drop target here")
  action(lasPending, "would " & $b.interaction.hover.get)

proc pixelOf*(event: MouseEvent): (float, float) =
  ## Where a report points, in pixels: its own pixel under SGR-pixel mode
  ## (1016), else the CENTRE of its cell through the measured cell size — so
  ## a report built from a row and a column alone is aimed the way a cell
  ## report from a terminal is.
  if event.pixel:
    return (event.px, event.py)
  let m = mouseMetrics()
  ((float(event.col) + 0.5) * m.cellW, (float(event.row) + 0.5) * m.cellH)

proc hoverAt*(b: LayoutBinding; geom: LayoutGeometry;
              row, col: int): LayoutAction =
  ## `hoverAtPx` at the CENTRE of cell `(row, col)` through the measured cell
  ## size — a terminal without SGR-pixel reports, and the keyboard's drags.
  let m = mouseMetrics()
  b.hoverAtPx(geom, (float(col) + 0.5) * m.cellW,
              (float(row) + 0.5) * m.cellH)

proc dropDrag*(b: LayoutBinding): LayoutAction =
  ## Let go. `commit` decides whether anything happened, by asking `apply`; the
  ## interaction is cleared either way, because a released button is not a drag
  ## whatever the answer was.
  if b.interaction.kind != ikDraggingTab:
    return action(lasNoGesture, "no drag in flight")
  let cmd = commit(b.layout, b.interaction)
  b.interaction = b.interaction.cancel()
  b.pointerRow = -1
  b.pointerCol = -1
  b.dragLayout = Layout()
  b.glPaths = @[]
  if cmd.isNone:
    return action(lasNoOp, "the drop changed nothing")
  b.dispatch(cmd.get)

proc cancelGesture*(b: LayoutBinding): LayoutAction =
  ## Abandon whatever is in flight. `cancel` takes no layout, so this cannot
  ## have changed one.
  if b.interaction.kind == ikNone:
    return action(lasNoGesture, "no gesture in flight")
  b.interaction = b.interaction.cancel()
  b.pointerRow = -1
  b.pointerCol = -1
  b.dragLayout = Layout()
  b.glPaths = @[]
  action(lasCancelled, "gesture cancelled")

proc beginRevealDock*(b: LayoutBinding; pane: PaneKind): LayoutAction =
  let revealed = beginReveal(b.layout, pane)
  if revealed.isNone:
    return action(lasNoGesture, $pane & " is not docked")
  b.interaction = revealed.get
  action(lasPending, "revealing " & $pane)

proc toggleDockOpen*(b: LayoutBinding; pane: PaneKind): LayoutAction =
  ## PLAT-49 part B (finding 9, the user's direction): A CLICK ON A DOCKED
  ## PANE'S LABEL DOCKS IT OPEN — inline at its edge, taking space from the
  ## arrangement, no longer an overlay (`cmdOpenDocked`, the desktop's
  ## `showDockedPanel`); a click on the label of the pane already open closes
  ## it again (`cmdCloseDocked`, `hideDockedPanel`). A hover preview of it
  ## ends first, as the desktop's click hides its overlay.
  if b.interaction.kind == ikRevealingDock:
    b.interaction = b.interaction.cancel()
  let at = b.layout.dockedIndex(pane)
  if at < 0:
    return action(lasNoGesture, $pane & " is not docked")
  if b.layout.docked[at].open:
    b.dispatch(cmdCloseDocked(pane))
  else:
    b.dispatch(cmdOpenDocked(pane))

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
  ##
  ## The tab the cell is ON — not `pointerAt`'s drop answer, which since
  ## PLAT-49 part B names the tab AFTER this one over its right half
  ## (GoldenLayout's insertion rule): a click there is still a click on
  ## this tab.
  let idx = geom.regionIndexAt(row, col)
  if idx < 0:
    return none(PaneKind)
  let region = geom.projection.regions[idx]
  if region.activeTab < 0 or region.tabs.len == 0 or row != region.area.row:
    return none(PaneKind)
  let at = tabSpanAt(region.tabs, region.activeTab, col - region.area.col)
  let panePath = geom.pathOfPane(region.pane)
  if at < 0 or panePath.isNone:
    return none(PaneKind)
  let stackPath = parentPath(panePath.get)
  if stackPath.isNone:
    return none(PaneKind)
  let info = nodeInfoAtPath(b.layout.tree, childPathOf(stackPath.get, at))
  if info.isNone or info.get.kind != lnPane:
    return none(PaneKind)
  some(info.get.pane)

proc onStripLabel(b: LayoutBinding; geom: LayoutGeometry; idx, col: int): bool =
  ## PLAT-50: whether `col` of a LONE pane's strip row (region `idx`) is on
  ## its one label rather than the strip's empty ground. A stack's tabs are
  ## resolved before either caller asks (`tabAtCell`, first in `onMouse` and
  ## in `stripPaneAt`), so for a stack every cell asked about is ground.
  let region = geom.projection.regions[idx]
  let at = col - region.area.col
  if region.activeTab >= 0 and region.tabs.len > 0:
    return false
  let label =
    if region.pane == paneEditor: LoneEditorLabelCells
    else: textCells(" " & terminalPaneName(region.pane) & " ")
  at >= 0 and at < label

proc stripPaneAt*(b: LayoutBinding; geom: LayoutGeometry;
                  row, col: int): Option[PaneKind] =
  ## PLAT-50: the pane whose TAB is under `(row, col)` — a stack's tab, or a
  ## lone pane's one label — for a right-click's tab menu
  ## (`pane_clicks.tabContextMenu`).
  let tab = b.tabAtCell(geom, row, col)
  if tab.isSome:
    return tab
  let idx = geom.regionIndexAt(row, col)
  if idx < 0:
    return none(PaneKind)
  let region = geom.projection.regions[idx]
  if region.activeTab < 0 and row == region.area.row and
     b.onStripLabel(geom, idx, col):
    return some(region.pane)
  none(PaneKind)

proc dividerAt(b: LayoutBinding; geom: LayoutGeometry;
               row, col: int): Option[(string, int)] =
  ## The divider a cell sits on, as `(container path, divider index)` — the
  ## pair `beginResizeDivider` takes — or `none`.
  ##
  ## A region's LAST column is on the divider to its right when the cell just
  ## past it belongs to a different region and the two panes are adjacent
  ## children (i and i + 1) of one ROW; its last row is on the divider below
  ## it the same way for a COLUMN. Answered from the two panes' node paths
  ## (their deepest common container, and the child each sits under), so
  ## a divider between two stacks or two nested rows is found exactly as one
  ## between two panes is. A cell where the two regions meet only at a corner,
  ## or across a container of the other axis, is on no divider this gesture
  ## can move.
  ##
  ## PLAT-50: THE HORIZONTAL DIVIDER IS THE LOWER PANE'S TAB STRIP. There is no
  ## divider row between vertically adjacent panes any more (the strip is the
  ## separator, `shell.paneFrame`), so a vertical resize is picked up on the
  ## lower pane's strip row OFF its tabs — the strip's empty ground, the way
  ## GoldenLayout's header is the edge of the stack below a splitter. The pair
  ## answered is the UPPER pane's, as the old divider row's was.
  let idx = geom.regionIndexAt(row, col)
  if idx < 0:
    return none((string, int))
  let pane = geom.projection.regions[idx].pane
  let area = geom.regionOfPane(pane)
  let here = geom.pathOfPane(pane)
  if here.isNone:
    return none((string, int))
  proc between(first, second: string; kind: LayoutNodeKind): Option[(string, int)] =
    ## The divider between two panes' subtrees when they are adjacent
    ## children (i, i + 1) of one container of `kind`.
    let a = first.split('/')
    let z = second.split('/')
    var k = 0
    while k < a.len and k < z.len and a[k] == z[k]:
      inc k
    if k >= a.len or k >= z.len:
      return none((string, int))
    let container = a[0 ..< k].join("/")
    var ia, iz: int
    try:
      ia = parseInt(a[k])
      iz = parseInt(z[k])
    except ValueError:
      return none((string, int))
    let info = nodeInfoAtPath(b.layout.tree, container)
    if info.isNone or iz != ia + 1 or info.get.kind != kind:
      return none((string, int))
    some((container, ia))
  # The vertical divider: the region's last column, the next pane right.
  if col == area.col + area.width - 1:
    let other = geom.regionIndexAt(row, col + 1)
    if other >= 0 and other != idx:
      let there = geom.pathOfPane(geom.projection.regions[other].pane)
      if there.isSome:
        let found = between(here.get, there.get, lnRow)
        if found.isSome:
          return found
  # The horizontal one: this pane's strip row, the pane above it.
  if row == area.row and row > 0 and not b.onStripLabel(geom, idx, col):
    let other = geom.regionIndexAt(row - 1, col)
    if other >= 0 and other != idx:
      let there = geom.pathOfPane(geom.projection.regions[other].pane)
      if there.isSome:
        return between(there.get, here.get, lnColumn)
  none((string, int))

proc dividerFraction(b: LayoutBinding; geom: LayoutGeometry; node: string;
                     row, col: int): Option[float] =
  ## The divider of the container of `node`, moved to the cell `(row, col)`,
  ## as a FRACTION of the container's extent — the model's own unit.
  let container = parentPath(node)
  if container.isNone:
    return none(float)
  let info = nodeInfoAtPath(b.layout.tree, container.get)
  let bounds = geom.boundsOfPath(container.get)
  if info.isNone or bounds.isEmptyArea:
    return none(float)
  some(if info.get.kind == lnRow:
         float(col - bounds.col + 1) / float(bounds.width)
       else:
         float(row - bounds.row + 1) / float(bounds.height))

proc previewDivider(b: LayoutBinding; geom: LayoutGeometry;
                    row, col: int): LayoutAction =
  ## PLAT-47: a divider drag's LIVE preview — the pointer moved with the
  ## button down, so the proposal follows it and the guide
  ## (`resizeGuideFor`) is redrawn where the divider would now land. Nothing
  ## is committed; the release does that.
  let fraction = b.dividerFraction(geom, b.interaction.node, row, col)
  if fraction.isNone:
    return action(lasPending, "the divider's container is not on screen")
  b.interaction = b.interaction.proposeDivider(b.layout, fraction.get)
  action(lasPending, "dragging the divider")

proc dropDivider(b: LayoutBinding; geom: LayoutGeometry;
                 row, col: int): LayoutAction =
  ## Release a divider drag at `(row, col)`: the divider goes to that cell's
  ## edge, as a FRACTION of its container's extent — the model's own unit —
  ## and `commit` decides whether that is a change.
  let gesture = b.interaction
  b.interaction = b.interaction.cancel()
  let fraction = b.dividerFraction(geom, gesture.node, row, col)
  if fraction.isNone:
    return action(lasNoOp, "the divider's container is not on screen")
  let cmd = commit(b.layout, gesture.proposeDivider(b.layout, fraction.get))
  if cmd.isNone:
    return action(lasNoOp, "the divider did not move")
  b.dispatch(cmd.get)

proc dragThresholdPassed*(b: LayoutBinding; row, col: int): bool =
  ## Whether `(row, col)` is far enough from the press for a drag.
  b.pressRow >= 0 and
    (abs(col - b.pressCol) >= DragThresholdCols or
     abs(row - b.pressRow) >= DragThresholdRows)

proc onMouse*(b: LayoutBinding; geom: LayoutGeometry;
              event: MouseEvent): LayoutAction =
  ## One decoded SGR-1006 report, as a layout gesture.
  ##
  ## A click and a drag are told apart by WHERE the button came up: released
  ## on the cell it went down on is a click, released anywhere else is a
  ## drop. That state machine needs no motion reports — a terminal that does
  ## not send them can still drag. Since PLAT-47 the driver ALSO asks for
  ## button-event motion (`?1002`), and a motion report while a drag is in
  ## flight moves the hover (the drop tint and the ghost label follow the
  ## pointer, GoldenLayout's feedback) and while a divider is held previews
  ## the divider; the release still decides, exactly as before.
  ##
  ##   * PLAT-49: A PRESS PICKS NOTHING UP. A press on a tab, on a bare
  ##     pane's one-tab strip or on a dock slot only MARKS that pane
  ##     (`pendingPick`); the drag begins when the pointer has moved
  ##     `DragThresholdCols` / `DragThresholdRows` from the press — on a
  ##     motion report, or (a terminal that sends none) on a release that
  ##     far away. A release before that is a click.
  ##   * press on a tab             -> mark that tab
  ##   * press on a bare pane's
  ##     strip row                  -> mark that PANE. A pane that is not in
  ##                                   a stack has one tab, and without this
  ##                                   rule the commonest shape on screen would
  ##                                   be undraggable
  ##   * press on a dock slot       -> mark that docked pane
  ##   * press on a region's last
  ##     column / row where the
  ##     neighbour across it is its
  ##     sibling                    -> pick that DIVIDER up (PLAT-5's divider
  ##                                   drag); release elsewhere moves it there,
  ##                                   release on the same cell is a click
  ##   * press elsewhere in a pane  -> focus it; no gesture
  ##   * release within the
  ##     threshold                  -> a click: activate the tab, or reveal the
  ##                                   docked pane; on a divider, nothing
  ##   * release past it            -> hover there, then drop
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
    if event.kind == mekMotion:
      # PLAT-47: THE POINTER MOVED WITH THE BUTTON DOWN (`?1002` motion). A
      # drag's drop indication and ghost follow it, and a divider's guide
      # previews where it would land; nothing else listens to motion.
      # PLAT-49: a marked tab becomes a drag only once the pointer is past
      # the threshold; a held divider previews only from then on.
      if b.pendingPick.isSome:
        if not b.dragThresholdPassed(event.row, event.col):
          return action(lasNoGesture, "within the drag threshold")
        let pane = b.pendingPick.get
        b.pendingPick = none(PaneKind)
        let started = b.beginDrag(pane)
        if b.interaction.kind != ikDraggingTab:
          return started
      case b.interaction.kind
      of ikDraggingTab:
        b.pointerRow = event.row
        b.pointerCol = event.col
        let (px, py) = pixelOf(event)
        return b.hoverAtPx(geom, px, py)
      of ikResizingSplit:
        if b.interaction.divider.isSome:
          if not b.dragThresholdPassed(event.row, event.col):
            return action(lasNoGesture, "within the drag threshold")
          return b.previewDivider(geom, event.row, event.col)
        return action(lasNoGesture, "motion during a share resize")
      else:
        return action(lasNoGesture, "the pointer moved; no gesture in flight")
    if event.kind == mekPress:
      b.pressRow = event.row
      b.pressCol = event.col
      b.pointerRow = event.row
      b.pointerCol = event.col
      b.pendingPick = none(PaneKind)
      b.pressWasRevealing = b.interaction.kind == ikRevealingDock
      if b.pressWasRevealing:
        b.pressRevealedPane = b.interaction.pane
      if b.pressWasRevealing:
        # PLAT-48: A REVEALED PANE IS AN OVERLAY. A press inside it belongs to
        # it and moves nothing behind it; a press outside it — anywhere but
        # its own strip label, whose release toggles it — hides it (the
        # desktop's auto-hide overlay closes on an outside click), and is
        # consumed by that.
        if geom.reveal.contains(event.row, event.col):
          return action(lasNoGesture, "inside the revealed " &
                                      $b.interaction.pane)
        let onStrip = geom.stripIndexAt(event.row, event.col)
        if onStrip < 0 or geom.strips[onStrip].slotAt(event.row,
                                                      event.col) < 0:
          b.pressRow = -1
          b.pressCol = -1
          let hidden = b.interaction.pane
          b.interaction = b.interaction.cancel()
          return action(lasCancelled, "hid " & $hidden)
      let tab = b.tabAtCell(geom, event.row, event.col)
      if tab.isSome:
        b.pendingPick = tab
        return action(lasNoGesture, "pressed the " & $tab.get & " tab")
      let strip = geom.stripIndexAt(event.row, event.col)
      if strip >= 0:
        let slot = geom.strips[strip].slotAt(event.row, event.col)
        if slot >= 0:
          b.pendingPick = some(geom.strips[strip].slots[slot].pane)
          return action(lasNoGesture, "pressed the " &
                                      $geom.strips[strip].slots[slot].pane &
                                      " label")
        return action(lasNoGesture, "an empty part of a dock strip")
      let idx = geom.regionIndexAt(event.row, event.col)
      if idx < 0:
        return action(lasNoGesture, "press outside the layout")
      let region = geom.projection.regions[idx]
      b.focus = region.pane
      if region.activeTab < 0 and event.row == region.area.row and
         b.onStripLabel(geom, idx, event.col):
        # A pane not in a stack is marked by its one tab. PLAT-50: on its
        # LABEL — the rest of the strip is the divider above (`dividerAt`).
        b.pendingPick = some(region.pane)
        return action(lasNoGesture, "pressed the " & $region.pane & " tab")
      let divider = b.dividerAt(geom, event.row, event.col)
      if divider.isSome:
        let started = beginResizeDivider(b.layout, divider.get[0],
                                         divider.get[1])
        if started.isSome:
          b.interaction = started.get
          return action(lasPending, "dragging the divider after " &
                                    $b.focus)
      return action(lasNoGesture, "focus " & $b.focus)
    # Release.
    let past = b.dragThresholdPassed(event.row, event.col)
    let pending = b.pendingPick
    b.pendingPick = none(PaneKind)
    b.pressRow = -1
    b.pressCol = -1
    if b.interaction.kind == ikResizingSplit and b.interaction.divider.isSome:
      if not past:
        # A click on the divider (within the threshold) is what it was
        # before the divider was draggable: a focus, and nothing committed.
        b.interaction = b.interaction.cancel()
        return action(lasNoGesture, "focus " & $b.focus)
      return b.dropDivider(geom, event.row, event.col)
    if pending.isSome:
      # A MARKED TAB, RELEASED. Within the threshold it is a click; past it
      # (a terminal that sent no motion reports) it is the whole drag at once.
      if past:
        discard b.beginDrag(pending.get)
      else:
        let source = pending.get
        if b.layout.dockedIndex(source) >= 0:
          return b.toggleDockOpen(source)
        return b.dispatch(cmdActivateTab(source))
    if b.interaction.kind != ikDraggingTab:
      # A plain click, or the release of a press that marked nothing: not a
      # drag, and nothing to say about one.
      return action(lasNoGesture, "click")
    let source = b.interaction.source
    if not past:
      # A CLICK. Cancel the drag first, so the click's own command is the only
      # thing that reaches `dispatch` — a drag that also committed would push
      # two entries onto one undo log for one gesture.
      discard b.cancelGesture()
      if b.layout.dockedIndex(source) >= 0:
        return b.toggleDockOpen(source)
      return b.dispatch(cmdActivateTab(source))
    let (px, py) = pixelOf(event)
    discard b.hoverAtPx(geom, px, py)
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
    lvPin = "pin"
      ## PLAT-48. The desktop's PIN: the focused pane goes to an auto-hide
      ## strip (`lcDock`; default edge: the footer, `bottom`).
    lvUnpin = "unpin"
      ## PLAT-48. The desktop's UNPIN: a docked pane goes back into the
      ## layout (`lcRestoreDocked`) — the revealed one, or the one named.

const
  LayoutVerbNames*: array[LayoutVerb, string] = [
    "move-tab", "move-pane", "merge-pane", "dock", "undock", "reveal",
    "hide", "resize", "focus", "undo-layout", "redo-layout", "reset-layout",
    "pin", "unpin"]
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
  b.history = newLayoutHistory(profileLayoutValue(b.profile))
  b.interaction = noInteraction()
  b.userModified = false
  action(lasApplied, "layout reset to the shared default")

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
  of lvPin:
    let edgeWord = if arg.len == 0: "bottom" else: arg
    let (ok, edge) = parseEdgeWord(edgeWord)
    if not ok:
      return action(lasBadArgument, ":pin needs left|right|top|bottom")
    if b.interaction.kind == ikRevealingDock:
      return action(lasNoOp, $b.interaction.pane & " is already pinned")
    b.dispatch(cmdDock(b.focus, edge))
  of lvUnpin:
    var pane = b.focus
    if arg.len > 0:
      let (ok, named) = parsePaneWord(arg)
      if not ok:
        return action(lasBadArgument,
                      ":unpin needs the name of a docked pane, not '" & arg &
                      "'")
      pane = named
    elif b.interaction.kind == ikRevealingDock:
      pane = b.interaction.pane
    if b.layout.dockedIndex(pane) < 0:
      return action(lasRefused, $pane & " is not pinned to a strip")
    b.interaction = noInteraction()
    # Back beside the pane it was pinned from, while that pane is placed:
    # the docked entry remembers it (`DockedPane.beside`).
    b.dispatch(cmdRestoreDocked(pane))

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
  # PLAT-45: THE DEFAULT CHANGES ONLY WHEN THE FOLD DEPTH DOES. A profile is
  # now a size, and two sizes that need the same depth produce the same
  # default — so re-flowing on every resize would throw away the active tab
  # for nothing. The depth is Debug mode's: the binding holds the Debug
  # arrangement (Edit mode's is the mode register's).
  let before = depthFor(pmDebug, b.profile)
  b.profile = selected
  if b.userModified:
    return false
  if depthFor(pmDebug, selected) == before:
    # The same arrangement, re-shared for the new size in place: the active
    # tabs stay as the user chose them, and the editor keeps its minimum
    # rather than the old size's cell counts. Not a re-flow.
    resizeShares(b.layout.tree, pmDebug, selected)
    return false
  b.history = newLayoutHistory(profileLayoutValue(selected))
  b.interaction = noInteraction()
  true

proc saveDocument*(b: LayoutBinding): JsonNode =
  ## The committed layout as a versioned document — tree, docked panes and all.
  ## `revealed` is not in it, because `toJson` omits it (§3.2) and because the
  ## authority on "is this overlay open" is `Interaction`, which is not part of
  ## a `Layout` at all.
  saveLayout(b.layout)

proc restoreDocument*(b: LayoutBinding; doc: JsonNode;
                      problem: var Option[LayoutDecodeErrorKind]):
    LayoutAction =
  ## Adopt a saved arrangement. A decode failure is REPORTED by kind, never
  ## swallowed: `layout_model` raises `LayoutDecodeError` precisely so a
  ## restore that names an unknown pane is a message rather than a blank
  ## region.
  ##
  ## `problem` carries that kind out AS A VALUE, which is the half the message
  ## cannot serve: a status line needs prose and a check needs a kind, and
  ## matching a kind out of prose is how a check ends up asserting the wording.
  ## `app/layout/persistence.adoptLayoutDocument` is the caller that needs it.
  ##
  ## **`userModified` IS SET, AND THAT IS A DECISION.** A restored document is
  ## a user modification made in a previous session, so it freezes the
  ## responsive profile exactly as this session's own first command would —
  ## `app/layout/persistence.nim`'s header states the reasoning and
  ## `:reset-layout` is the way back.
  ##
  ## `revealed` cannot come back either, and that needs no rule here:
  ## `toJson(DockedPane)` never writes it (§3.2) and `interaction` is reset
  ## below, so an overlay a previous session had open is not expressible in the
  ## document at all.
  problem = none(LayoutDecodeErrorKind)
  try:
    let restored = restoreLayoutDocument(doc)
    b.history = newLayoutHistory(restored)
    b.interaction = noInteraction()
    b.userModified = true
    action(lasApplied, "layout restored")
  except LayoutDecodeError as e:
    problem = some(e.kind)
    action(lasBadArgument, "the saved layout could not be read: " & e.msg)

proc restoreDocument*(b: LayoutBinding; doc: JsonNode): LayoutAction =
  ## The same restore for a caller that only wants the message.
  var problem = none(LayoutDecodeErrorKind)
  b.restoreDocument(doc, problem)
