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

  GestureStep* = object
    changed*: bool
      ## The window must be redrawn (a preview moved, an indication changed).
    command*: Option[LayoutCommand]
      ## A command the release produced, for the host to apply through the
      ## shell's one door (`GpuiShell.applyIn`).
    status*: string
      ## What happened, in words — a `--gesture-trace` line.

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
    if abs(x - g.pressX) > ClickSlopPx or abs(y - g.pressY) > ClickSlopPx:
      g.moved = true
    if not g.moved:
      return GestureStep(status: "")
    let pointer = geom.pointerAt(x, y)
    if pointer.isSome:
      # A pane picked up from a strip is no longer shown over the tree.
      g.reveal = noInteraction()
      g.interaction = hoverAt(g.interaction, layout, pointer.get)
    else:
      g.interaction = Interaction(kind: ikDraggingTab,
                                  source: g.interaction.source,
                                  origin: g.interaction.origin,
                                  hover: none(DropTarget))
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
        # A CLICK ON A DOCKED PANE'S LABEL: reveal it, or hide it again.
        if g.reveal.isRevealed(was.source):
          g.reveal = noInteraction()
          return GestureStep(changed: true,
                             status: "reveal dismissed " & $was.source)
        let shown = beginReveal(layout, was.source)
        g.reveal = if shown.isSome: shown.get else: noInteraction()
        return GestureStep(changed: true,
                           status: (if shown.isSome: "revealed " & $was.source
                                    else: "not docked: " & $was.source))
      return GestureStep(changed: true,
                         command: some(cmdActivateTab(was.source)),
                         status: "activateTab(" & $was.source & ")")
    let cmd = commit(layout, moved.interaction)
    GestureStep(changed: true, command: cmd,
                status: (if cmd.isSome: "drop applied" else: "drop: nothing"))

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

proc previewLayout*(g: WindowGestures; layout: Layout): Layout =
  ## What the window draws: the committed layout, or — while a divider is
  ## dragged — the committed layout with the pending resize applied.
  if g.kind != gkResize:
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
