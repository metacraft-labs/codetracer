## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/input/motions.nim — CTUI-9. The Vim motions of CodeTracer-TUI.md §4.2:
## `h`/`j`/`k`/`l`, `Ctrl+u`/`Ctrl+d`, `g``g`/`G`, `Tab`/`Shift+Tab`, `Ctrl+w`
## directional focus and `z` maximize.
##
## ## FOCUS IS ISONIM-TUI's, NOT A SECOND ONE
##
## CTUI-9: "reusing `isonim-tui`'s focus manager rather than building one." So
## `PaneFocus` builds a tree of `TerminalNode`s — one per VISIBLE pane, in
## projection order, each carrying the `data-focusable="true"` attribute
## `isonim_tui/focus/manager.isFocusable` looks for — and then does nothing
## itself: `focusNextPane` is `FocusManager.focusNext`, `focusPrevPane` is
## `focusPrev`, and the cycle order, the wrap and the `focus`/`blur` events are
## all that library's.
##
## A TREE IS NEEDED BECAUSE THE SHELL DOES NOT HAVE ONE. `app/views/shell.nim`
## composes the screen row by row (see its header on why isonim-tui's compositor
## forces that), so the component tree it renders has one `div` per SCREEN ROW
## and no node that stands for a pane. The projection — `app/layout/project.nim`
## — is where panes exist as objects, so that is what this module lifts into a
## focus chain. The chain is therefore a statement about the LAYOUT, which is
## what §4.2's "cycle active focus forward or backward through visible panes"
## asks for.
##
## ## WHAT THIS MODULE OWNS AND WHAT IT REFUSES TO
##
## It answers WHERE focus goes, HOW FAR a scroll goes, and WHICH pane a
## maximize covers. It never scrolls anything and never repaints: every entry
## point returns a value. That is what lets `app/tests/test_pane_focus_cycle.nim`
## assert the whole cycle in all three layout profiles without a renderer, a
## session or a terminal.
##
## ## DIRECTIONAL FOCUS IS GEOMETRY, AND THE RULE IS WRITTEN DOWN
##
## `FocusManager` has no idea where a node is on screen — it is a tree order —
## so `Ctrl+w h/j/k/l` cannot come from it. The rule here is:
##
##   1. Only panes STRICTLY on the named side are candidates: for `h`, panes
##      whose right edge is at or left of the current pane's left edge.
##   2. Among those, the NEAREST one wins (largest right edge for `h`).
##   3. Ties are broken by the smallest distance between the two panes' centres
##      on the other axis, so `Ctrl+w h` from a right-hand column lands on the
##      pane beside it rather than on the one above it.
##   4. Remaining ties are broken by projection order, so the answer is total.
##
## It does NOT wrap. §4.2 says "Focus the pane to the left"; a wrap would make
## `Ctrl+w h` from the leftmost pane jump to the rightmost, which is the same
## keystroke meaning two opposite things depending on where the user was.

import std/[algorithm, strutils]

import isonim_tui

import headless_app/layout_model

import ../layout/profile
import ../layout/project
import ./keymap

export keymap

type
  FocusDirection* = enum
    ## `Ctrl+w` `h`/`j`/`k`/`l`.
    fdLeft = "left"
    fdDown = "down"
    fdUp = "up"
    fdRight = "right"

  PaneFocus* = ref object
    ## The focus chain for ONE projection, backed by `isonim-tui`'s manager.
    ##
    ## A `ref` because `FocusManager` is one and the two have the same
    ## lifetime; everything it answers is a value.
    manager*: FocusManager
    root*: TerminalNode
    regions*: seq[PaneRegion]
      ## In projection order, which is the order `projectLayout` places panes
      ## and therefore the order the focus chain visits them.
    nodeIds*: seq[int]
      ## `nodeIds[i]` is the focus-chain node for `regions[i]`.

  MaximizeState* = object
    ## `z`. Which pane is filling the screen, and whether one is.
    active*: bool
    pane*: PaneKind

  SeekEdge* = enum
    ## `g``g` and `G`: §4.2's "Jump execution pointer to tick 0 (beginning) or
    ## final tick (end)".
    seStart = "start"
    seEnd = "end"

const
  ScrollLineRows* = 1
    ## `j` / `k` / `Down` / `Up`: "Scroll visible source code" one line.

proc halfPage*(bodyHeight: int): int =
  ## `Ctrl+u` / `Ctrl+d`: "Half Page Up / Down".
  ##
  ## At least one row, so the key is never a no-op on a two-row pane — a
  ## half-page that rounded to zero would look exactly like an unbound key.
  max(1, bodyHeight div 2)

proc scrollDelta*(action: KeyAction; bodyHeight: int): (bool, int) =
  ## How many rows an action scrolls, signed, and whether it scrolls at all.
  ##
  ## Positive is DOWN — towards later lines — which is the direction
  ## `call_stack.clampScrollTop` and `source_pane` already count in, so a caller
  ## adds this to a `scrollTop` without negating anything.
  case action
  of kaScrollLineDown: (true, ScrollLineRows)
  of kaScrollLineUp: (true, -ScrollLineRows)
  of kaHalfPageDown: (true, halfPage(bodyHeight))
  of kaHalfPageUp: (true, -halfPage(bodyHeight))
  else: (false, 0)

proc seekEdgeFor*(action: KeyAction): (bool, SeekEdge) =
  ## `g``g` -> the beginning, `G` -> the end.
  case action
  of kaJumpToStart: (true, seStart)
  of kaJumpToEnd: (true, seEnd)
  else: (false, seStart)

proc edgeTick*(edge: SeekEdge; minTick, maxTick: uint64): uint64 =
  ## The tick an edge seeks to, clamped so an inverted or empty range answers
  ## `minTick` rather than a tick that is not in the recording.
  case edge
  of seStart: minTick
  of seEnd: (if maxTick < minTick: minTick else: maxTick)

# ---------------------------------------------------------------------------
# Direct pane selection — §4.2's `1` / `2` / `3` / `4`
# ---------------------------------------------------------------------------

proc directSelectPane*(action: KeyAction): (bool, PaneKind) =
  ## §4.2: "Focus Call Stack (1), Source (2), Variables (3), Timeline (4)".
  ##
  ## A pane the current profile does not show cannot be focused, and
  ## `focusPaneKind` below reports that rather than silently focusing something
  ## else — the Compact profile shows the timeline only as a tab, so `4` there
  ## is a real question rather than an oversight.
  case action
  of kaSelectCallStack: (true, paneCalltrace)
  of kaSelectSource: (true, paneEditor)
  of kaSelectVariables: (true, paneState)
  of kaSelectTimeline: (true, paneTimeline)
  else: (false, paneEditor)

# ---------------------------------------------------------------------------
# The focus chain
# ---------------------------------------------------------------------------

proc newPaneFocus*(projection: Projection): PaneFocus =
  ## Lift a projection's visible panes into an `isonim-tui` focus chain.
  ##
  ## One node per region, appended in projection order, each marked focusable.
  ## `FocusManager.focusChain` is a DFS pre-order walk, and a flat list's DFS
  ## order IS its insertion order — so the chain this returns is the order the
  ## panes are laid out in, which is what makes `Tab`'s order stable across
  ## repaints rather than dependent on which pane was painted last.
  var r: TerminalRenderer
  let root = r.createElement("div")
  result = PaneFocus(manager: newFocusManager(), root: root, regions: @[],
                     nodeIds: @[])
  for region in projection.regions:
    let node = r.createElement("div")
    r.setAttribute(node, "data-focusable", "true")
    r.setAttribute(node, "data-pane", $region.pane)
    r.appendChild(root, node)
    result.regions.add region
    result.nodeIds.add node.id
  if result.nodeIds.len > 0:
    discard result.manager.setFocus(root, result.nodeIds[0])

proc indexOfNode(pf: PaneFocus; id: int): int =
  for i, n in pf.nodeIds:
    if n == id:
      return i
  -1

proc focusedIndex*(pf: PaneFocus): int =
  ## Which region has focus, or -1.
  if pf.isNil: -1 else: pf.indexOfNode(pf.manager.focusedId)

proc focusedPane*(pf: PaneFocus): (bool, PaneKind) =
  let idx = pf.focusedIndex()
  if idx < 0: (false, paneEditor) else: (true, pf.regions[idx].pane)

proc focusOrder*(pf: PaneFocus): seq[PaneKind] =
  ## The panes `Tab` visits, in order — read out of `FocusManager.focusChain`
  ## rather than out of `regions`, so the sequence this reports is the one the
  ## library will actually walk.
  result = @[]
  for id in pf.manager.focusChain(pf.root):
    let idx = pf.indexOfNode(id)
    if idx >= 0:
      result.add pf.regions[idx].pane

proc focusNextPane*(pf: PaneFocus): (bool, PaneKind) =
  ## `Tab`. Wraps, which is what "cycle" means and what `FocusManager` does.
  if pf.nodeIds.len == 0:
    return (false, paneEditor)
  discard pf.manager.focusNext(pf.root)
  pf.focusedPane()

proc focusPrevPane*(pf: PaneFocus): (bool, PaneKind) =
  ## `Shift+Tab`.
  if pf.nodeIds.len == 0:
    return (false, paneEditor)
  discard pf.manager.focusPrev(pf.root)
  pf.focusedPane()

proc focusPaneKind*(pf: PaneFocus; kind: PaneKind): bool =
  ## Focus a pane by kind — §4.2's `1` / `2` / `3` / `4`. False when this
  ## profile does not show it.
  for i, region in pf.regions:
    if region.pane == kind:
      discard pf.manager.setFocus(pf.root, pf.nodeIds[i])
      return true
  false

# ---------------------------------------------------------------------------
# `Ctrl+w` h/j/k/l
# ---------------------------------------------------------------------------

# TWICE the geometric centre, kept in integers: two panes of different heights
# then compare exactly, rather than through a `div 2` that can make them tie by
# rounding and hand the tie-break to projection order for the wrong reason.
proc centreRow(a: CellArea): int = a.row * 2 + a.height
proc centreCol(a: CellArea): int = a.col * 2 + a.width

proc isBeyond(dir: FocusDirection; cur, other: CellArea): bool =
  ## Whether `other` lies STRICTLY on `dir`'s side of `cur`.
  case dir
  of fdLeft: other.col + other.width <= cur.col
  of fdRight: other.col >= cur.col + cur.width
  of fdUp: other.row + other.height <= cur.row
  of fdDown: other.row >= cur.row + cur.height

proc nearness(dir: FocusDirection; other: CellArea): int =
  ## How close `other`'s facing edge is, larger being nearer.
  case dir
  of fdLeft: other.col + other.width
  of fdRight: -other.col
  of fdUp: other.row + other.height
  of fdDown: -other.row

proc crossDistance(dir: FocusDirection; cur, other: CellArea): int =
  case dir
  of fdLeft, fdRight: abs(centreRow(cur) - centreRow(other))
  of fdUp, fdDown: abs(centreCol(cur) - centreCol(other))

proc directionFor*(action: KeyAction): (bool, FocusDirection) =
  case action
  of kaFocusLeft: (true, fdLeft)
  of kaFocusDown: (true, fdDown)
  of kaFocusUp: (true, fdUp)
  of kaFocusRight: (true, fdRight)
  else: (false, fdLeft)

proc paneInDirection*(regions: seq[PaneRegion]; fromIndex: int;
                      dir: FocusDirection): (bool, PaneKind) =
  ## Which pane lies one step `dir` of `regions[fromIndex]`, by geometry alone.
  ##
  ## PLAT-6 EXTRACTED THIS FROM the `PaneFocus` overload below, unchanged line
  ## for line, and the extraction is the point rather than tidiness: the
  ## terminal layout binding has to answer "which pane is to the left of the
  ## focused one" to turn `:move-pane left` into an `lcSplit`, and it holds a
  ## projection rather than an `isonim-tui` `FocusManager`. A second copy of
  ## these four comparisons would have been a second directional-navigation
  ## rule, and the day they disagreed `Ctrl+w h` and `:move-pane left` would
  ## have named different panes on the same screen.
  if fromIndex < 0 or fromIndex >= regions.len:
    return (false, paneEditor)
  let cur = regions[fromIndex].area
  var best = -1
  for i, region in regions:
    if i == fromIndex or not isBeyond(dir, cur, region.area):
      continue
    if best < 0:
      best = i
      continue
    let a = regions[best].area
    let bArea = region.area
    let na = nearness(dir, a)
    let nb = nearness(dir, bArea)
    if nb > na:
      best = i
    elif nb == na and
         crossDistance(dir, cur, bArea) < crossDistance(dir, cur, a):
      best = i
    # A remaining tie keeps `best`, which is the earlier projection index — the
    # fourth rule in this module's header, and what makes the answer total.
  if best < 0:
    return (false, paneEditor)
  (true, regions[best].pane)

proc paneInDirection*(pf: PaneFocus; dir: FocusDirection): (bool, PaneKind) =
  ## Which pane `Ctrl+w <dir>` would land on, without moving focus.
  ##
  ## Exposed separately from `focusDirection` so a test can assert the CHOICE
  ## at every geometry without also asserting that focus moved — two facts, and
  ## a helper that folded them would let a broken chooser hide behind a focus
  ## call that happened to succeed.
  paneInDirection(pf.regions, pf.focusedIndex(), dir)

proc focusDirection*(pf: PaneFocus; dir: FocusDirection): (bool, PaneKind) =
  ## Move focus one pane in `dir`. False, and focus UNCHANGED, when there is no
  ## pane that way — see the header on why this does not wrap.
  let (found, kind) = pf.paneInDirection(dir)
  if not found:
    return (false, paneEditor)
  if not pf.focusPaneKind(kind):
    return (false, paneEditor)
  (true, kind)

# ---------------------------------------------------------------------------
# `z` — maximize and restore
# ---------------------------------------------------------------------------

proc initMaximizeState*(): MaximizeState =
  MaximizeState(active: false, pane: paneEditor)

proc toggleMaximize*(state: var MaximizeState; focused: PaneKind): bool =
  ## §4.2: "Temporarily maximize the currently focused pane to fill the
  ## screen." Returns whether the screen is maximized AFTER the toggle.
  ##
  ## Pressing `z` on a DIFFERENT pane while one is maximized maximizes that one
  ## instead of restoring — restoring first would cost the user a keystroke to
  ## express "actually, this one", and the state is still one boolean.
  if state.active and state.pane == focused:
    state.active = false
    return false
  state.active = true
  state.pane = focused
  true

proc maximizedLayout*(pane: PaneKind; title = ""): LayoutNode =
  ## The layout a maximized pane gets: THE SAME `LayoutNode` TYPE the profiles
  ## build and the desktop persists, holding one pane.
  ##
  ## Built rather than achieved by hiding siblings, because `projectLayout`'s
  ## own totality checks (`coverageProblems`) then apply to the maximized screen
  ## unchanged — a maximize that left invisible zero-width regions behind would
  ## be reported by the projection instead of discovered on a screenshot.
  layout_model.pane(pane, title)

proc layoutFor*(state: MaximizeState; profile: LayoutProfile): LayoutNode =
  ## The tree to project: one pane while maximized, the profile's own
  ## otherwise.
  if state.active: maximizedLayout(state.pane)
  else: profileLayout(profile)

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

proc describeFocusOrder*(pf: PaneFocus): string =
  ## The cycle as one line, for a failure message that has to say what the
  ## order WAS.
  var parts: seq[string] = @[]
  for kind in pf.focusOrder():
    parts.add $kind
  parts.join(" -> ")

proc sortedPaneNames*(panes: seq[PaneKind]): seq[string] =
  ## Pane names in a stable order, so a set comparison in a test reports a
  ## readable difference rather than two shuffled lists.
  result = @[]
  for p in panes:
    result.add $p
  result.sort()
