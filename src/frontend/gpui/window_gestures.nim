## window_gestures.nim — the GPUI window's pointer gestures on the layout: a
## tab dragged to a drop, a divider dragged to a new split. PLAT-47
## deliverables 5 and 6, GPUI's half.
##
## ## The layout model decides; this only converts
##
## Every decision is `layout_interaction`'s, reached through the window's
## hit-test (`window_geometry.pointerAt` / `dividerAt`):
##
##   * a press on a divider gap is `beginResizeDivider(container, index)`;
##     each move is `proposeDivider(fraction)`; the release is `commit`, which
##     issues `cmdSetDivider` — the same three calls the terminal's divider
##     drag makes;
##   * a press on a tab (or a bare pane's title row) is `beginDragTab`; each
##     move is `hoverAt(pointerAt(x, y))`; the release is `commit` — or, when
##     the pointer never left the press's neighbourhood, a CLICK, which
##     activates the tab (`cmdActivateTab`);
##   * `Esc` is `cancel`: the committed layout was never touched.
##   * a press on a docked pane's label in an AUTO-HIDE STRIP picks the pane
##     up (`beginDragTab` of a docked pane: dropping it into the tree places
##     it again); released without moving it is a CLICK, which REVEALS the
##     pane over the tree (`beginReveal`) — or hides it again when it was
##     the one revealed. A reveal is dismissed by `Esc`, by a second click on
##     its label, and by a press anywhere outside the revealed pane (focus
##     leaving it); it never touches the committed layout.
##
## The LIVE PREVIEW of a resize is the model's too: `previewLayout` applies
## the pending command (`pendingCommand` then `apply`) to a copy of the
## committed layout, and the window draws that — so what a user sees while
## dragging is exactly what the release will commit.
##
## The pointer position is a MEASUREMENT and is held here, never in the
## `Interaction` (PLAT-5's purity law), for the ghost label to follow.
##
## Pure: no renderer, no window.

import std/options

import ./window_geometry

type
  GestureKind* = enum
    gkNone
    gkDragTab
    gkResize

  WindowGestures* = object
    kind*: GestureKind
    interaction*: Interaction
    source*: PaneKind
      ## The dragged pane (`gkDragTab`).
    pressX*, pressY*: int
    pointerX*, pointerY*: int
    moved*: bool
      ## The pointer left the press's neighbourhood: a drag, not a click.
    divider*: GeomDivider
      ## The divider being dragged (`gkResize`), as it was at the press.
    grab*: int
      ## How far into the divider's gap the press landed, on its axis — kept
      ## so a press that does not move proposes the divider where it is.
    fromStrip*: bool
      ## The drag started on an auto-hide strip's label (`gkDragTab`).
    reveal*: Interaction
      ## The docked pane shown over the tree (`ikRevealingDock`), or
      ## `ikNone`. It OUTLIVES the gesture that opened it — a click reveals,
      ## and the pane stays shown after the button comes up — so every entry
      ## point below carries it across.
    dragLayout*: Layout
      ## PLAT-51: once a tab drag has moved, the arrangement WITHOUT the
      ## dragged pane (`dragLayoutFor`) — GoldenLayout's `DragProxy` takes
      ## the item out before it measures; the window draws this
      ## (`previewLayout`) and the hit-test measures it.
    glState*: GlDragState
    glPaths*: seq[string]
      ## PLAT-51: GoldenLayout's state between two samples of the drag (each
      ## stack's segment and index, the placeholder, the last valid area) and
      ## the stack paths it indexes.

  GestureStep* = object
    changed*: bool
      ## The window must be redrawn (a preview moved, an indication changed).
    command*: Option[LayoutCommand]
      ## A command the release produced, for the host to apply through the
      ## shell's one door (`GpuiShell.applyIn`).
    status*: string
      ## What happened, in words — a `--gesture-trace` line.
    relayout*: bool
      ## PLAT-51: the drawn arrangement changed SHAPE (the drag just lifted
      ## its pane out): the host lays the window out again and hands this
      ## sample back (`pointerMove`) against the new geometry.

const ClickSlopPx* = 4
  ## How far a pointer may wander between press and release and still be a
  ## click. A press is never pixel-exact on a real mouse.

func idle*(): WindowGestures =
  WindowGestures(kind: gkNone, interaction: noInteraction(),
                 reveal: noInteraction())

func active*(g: WindowGestures): bool = g.kind != gkNone

func revealing*(g: WindowGestures): bool =
  ## A docked pane is shown over the tree.
  g.reveal.kind == ikRevealingDock

proc idleKeepingReveal(g: WindowGestures): WindowGestures =
  result = idle()
  result.reveal = g.reveal

proc paneOf(id: string): Option[PaneKind] =
  for k in PaneKind:
    if $k == id:
      return some(k)
  none(PaneKind)

proc pointerDown*(g: var WindowGestures; layout: Layout;
                  geom: WindowGeometry; x, y: int): GestureStep =
  ## A left-button press at window pixel (x, y).
  g = g.idleKeepingReveal()
  # A DOCKED PANE'S LABEL: pick it up (a click, decided on release, reveals).
  let (strip, slot) = geom.slotAt(x, y)
  if strip >= 0:
    let pane = paneOf(geom.strips[strip].slots[slot].pane)
    if pane.isNone:
      return GestureStep(status: "a contributed pane is not dragged")
    let started = beginDragTab(layout, pane.get)
    if started.isNone:
      return GestureStep(status: "nothing to pick up")
    g = WindowGestures(kind: gkDragTab, interaction: started.get,
                       source: pane.get, pressX: x, pressY: y,
                       pointerX: x, pointerY: y, fromStrip: true,
                       reveal: g.reveal)
    return GestureStep(changed: false,
                       status: "dragging docked " & $pane.get)
  # A press OUTSIDE the revealed pane dismisses it (focus left it), and the
  # press then does what it does; a press inside it is the pane's own.
  var dismissed = false
  if g.revealing:
    if geom.revealRectOf(g.reveal.edge).contains(x, y):
      return GestureStep(status: "press in the revealed " & $g.reveal.pane)
    g.reveal = noInteraction()
    dismissed = true
  let d = geom.dividerAt(x, y)
  if d >= 0:
    let dv = geom.dividers[d]
    let started = beginResizeDivider(layout, dv.container, dv.index)
    if started.isSome:
      g = WindowGestures(kind: gkResize, interaction: started.get,
                         divider: dv, pressX: x, pressY: y,
                         pointerX: x, pointerY: y,
                         grab: (if dv.horizontal: x - dv.rect.x
                                else: y - dv.rect.y),
                         reveal: g.reveal)
      return GestureStep(changed: dismissed,
                         status: "resizing '" & dv.container & "' divider " &
                                 $dv.index)
    return GestureStep(changed: dismissed,
                       status: "no divider there the model can move")
  let (node, tab) = geom.tabAt(x, y)
  if node >= 0:
    let pane = paneOf(geom.nodes[node].panes[tab])
    if pane.isNone:
      return GestureStep(status: "a contributed pane is not dragged")
    let started = beginDragTab(layout, pane.get)
    if started.isNone:
      return GestureStep(status: "nothing to pick up")
    g = WindowGestures(kind: gkDragTab, interaction: started.get,
                       source: pane.get, pressX: x, pressY: y,
                       pointerX: x, pointerY: y, reveal: g.reveal)
    return GestureStep(changed: dismissed,
                       status: "dragging " & $pane.get)
  GestureStep(changed: dismissed,
              status: (if dismissed: "reveal dismissed"
                       else: "press outside any gesture"))

proc pointerMove*(g: var WindowGestures; layout: Layout;
                  geom: WindowGeometry; x, y: int): GestureStep =
  ## The pointer moved to (x, y) with the button held.
  case g.kind
  of gkNone:
    GestureStep(status: "")
  of gkResize:
    g.pointerX = x
    g.pointerY = y
    let axis = (if g.divider.horizontal: x else: y) - g.grab
    # The fraction against the divider AS IT WAS PRESSED: the container does
    # not move while its divider does.
    var probe = geom
    probe.dividers = @[g.divider]
    let fraction = probe.dividerFractionAt(0, axis)
    let before = g.interaction
    g.interaction = proposeDivider(g.interaction, layout, fraction)
    GestureStep(changed: g.interaction.proposed != before.proposed,
                status: "divider at " & $fraction)
  of gkDragTab:
    g.pointerX = x
    g.pointerY = y
    if not g.moved:
      if abs(x - g.pressX) > ClickSlopPx or abs(y - g.pressY) > ClickSlopPx:
        # THE DRAG BEGINS (PLAT-51): GoldenLayout's `DragProxy` lifts the
        # pane out of its stack before anything is measured, so the window
        # is laid out again without it and this sample is decided against
        # THAT geometry (`relayout`: the host redraws and calls again).
        g.moved = true
        g.dragLayout = dragLayoutFor(layout, g.source)
        g.glState = GlDragState(placeholderStack: -1, placeholderIndex: -1,
                                lastValid: -1)
        g.glPaths = @[]
        # A pane picked up from a strip is no longer shown over the tree.
        g.reveal = noInteraction()
        return GestureStep(changed: true, relayout: true,
                           status: "dragging " & $g.source)
      return GestureStep(status: "")
    # GOLDENLAYOUT'S `setDropPosition`, PORTED (Layout-ViewModel §4.2.2):
    # constrained onto the tree, `getArea`, the stack's segment or header
    # index and the placeholder, carried from the previous sample; a pointer
    # over no area (a gap between boxes) keeps the last valid one.
    let shown = if g.dragLayout.tree.isNil: layout else: g.dragLayout
    let hit = goldenHitOf(geom)
    if hit.paths != g.glPaths or g.glState.stacks.len != hit.geom.stacks.len:
      g.glState = glDragState(hit.geom)
      g.glPaths = hit.paths
    let (cx, cy) = glClamp(hit.geom, float(x), float(y))
    let d = glPointerStep(hit.geom, hit.areas, g.glState, cx, cy,
                          NativeCentreShare)
    g.interaction = hoverGolden(g.interaction, layout, shown,
                                goldenDropOf(d, hit.paths))
    let after = dropIndicationOf(g.interaction)
    # The ghost follows the pointer, so every move while dragging redraws.
    GestureStep(changed: true,
                status: (if after.kind == diNone: "no drop here"
                         else: "would " & $after.kind & " '" & after.path &
                               "'"))

proc pointerUp*(g: var WindowGestures; layout: Layout;
                geom: WindowGeometry; x, y: int): GestureStep =
  ## The button came up at (x, y). The gesture ends either way.
  let was = g
  g = g.idleKeepingReveal()
  case was.kind
  of gkNone:
    GestureStep(status: "")
  of gkResize:
    var moved = was
    discard moved.pointerMove(layout, geom, x, y)
    let cmd = commit(layout, moved.interaction)
    GestureStep(changed: true, command: cmd,
                status: (if cmd.isSome: "resize applied" else: "resize: no change"))
  of gkDragTab:
    var moved = was
    discard moved.pointerMove(layout, geom, x, y)
    if not moved.moved:
      if was.fromStrip:
        # PLAT-49 part B (finding 9, the user's direction): A CLICK ON A
        # DOCKED PANE'S LABEL DOCKS IT OPEN — inline at its edge, taking
        # space, no longer an overlay (`cmdOpenDocked`, the desktop's
        # `showDockedPanel`); a click on the open pane's label closes it
        # (`cmdCloseDocked`). A hover preview of it ends.
        g.reveal = noInteraction()
        let at = layout.dockedIndex(was.source)
        if at < 0:
          return GestureStep(changed: true,
                             status: "not docked: " & $was.source)
        let cmd = if layout.docked[at].open: cmdCloseDocked(was.source)
                  else: cmdOpenDocked(was.source)
        return GestureStep(changed: true, command: some(cmd), status: $cmd)
      return GestureStep(changed: true,
                         command: some(cmdActivateTab(was.source)),
                         status: "activateTab(" & $was.source & ")")
    let cmd = commit(layout, moved.interaction)
    GestureStep(changed: true, command: cmd,
                status: (if cmd.isSome: "drop applied" else: "drop: nothing"))

proc previewReveal*(g: var WindowGestures; layout: Layout;
                    pane: PaneKind): bool =
  ## PLAT-49 part B: the hover preview — `pane` shown over the tree as an
  ## overlay (`beginReveal`), as the desktop's `showOverlayPreview`. Not
  ## during a drag or a resize. True when it is now shown.
  if g.kind != gkNone:
    return false
  let shown = beginReveal(layout, pane)
  if shown.isNone:
    return false
  g.reveal = shown.get
  true

proc dismissReveal*(g: var WindowGestures; pane: PaneKind): bool =
  ## PLAT-49 part B: the preview of `pane` closes (the pointer left it).
  if g.reveal.isRevealed(pane):
    g.reveal = noInteraction()
    return true
  false

proc cancelGesture*(g: var WindowGestures): GestureStep =
  ## `Esc`: the gesture in flight is discarded, the committed layout
  ## untouched; with none in flight, a revealed docked pane is hidden.
  let was = g.kind
  if was == gkNone and g.revealing:
    g = idle()
    return GestureStep(changed: true, status: "reveal dismissed")
  g.interaction = cancel(g.interaction)
  g = g.idleKeepingReveal()
  GestureStep(changed: was != gkNone,
              status: (if was != gkNone: "gesture cancelled" else: ""))

proc placeholderOf*(g: WindowGestures): tuple[found: bool; stackPath: string;
                                             index: int] =
  ## PLAT-51: where GoldenLayout's tab-drop PLACEHOLDER is during a drag —
  ## the pane box (its path) and the tab it sits before. The window opens a
  ## `GlPlaceholderPx` gap there, as GoldenLayout's strip does.
  if g.kind != gkDragTab or not g.moved or g.glState.placeholderStack < 0 or
     g.glState.placeholderStack >= g.glPaths.len:
    return (false, "", -1)
  (true, g.glPaths[g.glState.placeholderStack], g.glState.placeholderIndex)

proc previewLayout*(g: WindowGestures; layout: Layout;
                    liveResize = true): Layout =
  ## What the window draws: the committed layout; during a tab drag that has
  ## moved, the layout WITHOUT the dragged pane (`dragLayout`, GoldenLayout's
  ## drag proxy); while a divider is dragged with live resize on (PLAT-51,
  ## Layout-ViewModel §4.3a, the default), the committed layout with the
  ## pending resize applied — every pane at its proposed size. With live
  ## resize off the arrangement stays and a guide marks the divider
  ## (`resizeGuideOf`).
  if g.kind == gkDragTab and g.moved and not g.dragLayout.tree.isNil:
    return g.dragLayout
  if g.kind != gkResize or not liveResize:
    return layout
  let cmd = pendingCommand(layout, g.interaction)
  if cmd.isNone:
    return layout
  let outcome = apply(layout, cmd.get)
  if outcome.kind == loApplied: outcome.layout else: layout

proc indication*(g: WindowGestures): DropIndication =
  ## The drop in flight, as the window draws it: nothing until the pointer
  ## has moved off the press.
  if g.kind != gkDragTab or not g.moved:
    return DropIndication(kind: diNone)
  dropIndicationOf(g.interaction)

proc resizeGuideOf*(g: WindowGestures; geom: WindowGeometry): PxRect =
  ## PLAT-51: with live resize OFF, where the dragged divider would land —
  ## a band the gap's thickness across its container at the pointer's
  ## position (the committed arrangement does not move until release).
  if g.kind != gkResize:
    return PxRect()
  let d = g.divider
  if d.horizontal:
    let x = max(d.start, min(d.start + d.extent, g.pointerX - g.grab))
    PxRect(x: x, y: d.rect.y, w: max(2, d.rect.w), h: d.rect.h)
  else:
    let y = max(d.start, min(d.start + d.extent, g.pointerY - g.grab))
    PxRect(x: d.rect.x, y: y, w: d.rect.w, h: max(2, d.rect.h))
