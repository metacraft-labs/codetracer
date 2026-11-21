## element_reuse.nim — a redraw keeps the elements whose content did not move.
##
## The window draws a pane again after every move of the debugger, and until
## this module every redraw built every element of the pane anew. The shim's
## shadow tree (isonim-gpui `docs/incremental-rendering.md`) rebuilds the
## render plan only of nodes that changed, and replays unchanged subtrees
## behind cached views — but a node built anew is a changed node, so a window
## whose panes were rebuilt cost the shim a walk over nearly every element on
## every step.
##
## A draw that goes through an `ElementPool` asks it for each keyed piece —
## an editor row, a table row, a pane's scrollbar — by a STABLE KEY (the
## row's line, the event's index) and a DIGEST of everything the piece is
## drawn from. When the pool holds an element drawn last time under that key
## from the same digest, that element is handed back and appended where the
## new one would have been: it receives no write, so the shim keeps its
## cached plan, and its id stays. Otherwise the piece is built as before and
## remembered for the next draw. Whatever the last draw built and this one
## did not take is destroyed when the draw finishes.
##
## The digest is the contract. It must cover every input the piece's draw
## reads — its row, the pane's width, the theme — because a piece whose
## digest matches is not drawn at all. `test_gpui_keyed_redraw.nim` holds the
## contract from outside: the same scripted steps give the same window render
## plan with the pools on and with them off.
##
## Listeners need no digest: the window wires a row's listeners from its
## attributes when they fire (`window_clicks.wireOne`), so a reused row's
## handler reads what the row says now, not what it said when it was wired.
##
## `CODETRACER_GPUI_FULL_REDRAW=1` turns every pool off — each piece is built
## anew, the behaviour before this module — for the equivalence test and as
## the control of the per-step measurement.

import std/[hashes, os, tables]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_create_element, gpui_destroy_tree

export hashes

let fullRedraw* = getEnv("CODETRACER_GPUI_FULL_REDRAW").len > 0
  ## Every pool off: every redraw builds every element (the control).

type
  Drawn = object
    digest: Hash
    el: GpuiElement

  ElementPool* = object
    ## The keyed pieces one list or pane drew last time.
    prev, cur: Table[string, Drawn]
    open: bool
    reused*, built*: int
      ## This draw's pieces handed back and built, for `--frame-report`.

  ReuseTally* = object
    ## Every pool's pieces reused and built since the window opened, for
    ## the frame report and the churn report (each reads a difference).
    reused*, built*: int

var tally: ReuseTally

proc reuseTotals*(): ReuseTally =
  ## The pieces every pool has reused and built so far.
  tally

proc begin*(p: var ElementPool) =
  ## Start a draw. What the previous draw built becomes what this one may
  ## take; a draw left open (an exception mid-draw) is finished first.
  if p.open:
    for _, d in p.prev:
      if not d.el.isNil and parentNode(GpuiRenderer(), d.el).isNil:
        gpui_destroy_tree(d.el)
  p.prev = move p.cur
  p.cur = initTable[string, Drawn]()
  p.open = true
  p.reused = 0
  p.built = 0

proc take*(p: var ElementPool; key: string; digest: Hash): GpuiElement =
  ## The element drawn last time under `key` from `digest`, or nil. Taken
  ## once: a second piece under one key in one draw is built.
  if fullRedraw or not p.open or key in p.cur:
    return nil
  var d: Drawn
  if p.prev.pop(key, d):
    if d.digest == digest and not d.el.isNil:
      p.cur[key] = d
      inc p.reused
      inc tally.reused
      return d.el
    # Drawn from other inputs: it is not taken, and goes with the leftovers.
    p.prev[key & "\0stale"] = d

proc keep*(p: var ElementPool; key: string; digest: Hash; el: GpuiElement) =
  ## Remember `el`, just built under `key` from `digest`, for the next draw.
  inc p.built
  inc tally.built
  if p.open and key notin p.cur:
    p.cur[key] = Drawn(digest: digest, el: el)

proc finish*(p: var ElementPool) =
  ## End a draw: every piece the last draw built and this one did not take
  ## is destroyed, unless something attached it elsewhere since.
  for _, d in p.prev:
    if not d.el.isNil and parentNode(GpuiRenderer(), d.el).isNil:
      gpui_destroy_tree(d.el)
  p.prev = initTable[string, Drawn]()
  p.open = false

proc forget*(p: var ElementPool) =
  ## Drop every remembered piece without destroying it (its pane was torn
  ## down with the elements in it).
  p.prev = initTable[string, Drawn]()
  p.cur = initTable[string, Drawn]()
  p.open = false

template keyed*(p: var ElementPool; key: string; digest: Hash;
                build: untyped): GpuiElement =
  ## The piece under `key`: the element drawn last time from `digest`, or
  ## `build` evaluated (and remembered).
  block:
    let k = key
    let dg = digest
    var el = p.take(k, dg)
    if el.isNil:
      el = build
      p.keep(k, dg, el)
    el

var styleMemo: Table[(uint64, string), string]
  ## The value each `setStyleOnce` last gave an element's property.

proc styleIsSet(id: uint64; prop, value: string): bool =
  styleMemo.getOrDefault((id, prop), "\0") == value

proc setStyleOnce*(r: GpuiRenderer; el: GpuiElement; prop, value: string) =
  ## `r.setStyle(el, prop, value)` unless this is the value it was last given
  ## through here: the walks that run over the whole window after every
  ## redraw (the faces, the pointer's cursor) would otherwise write every
  ## element, and a write marks the element changed in the shim whether or
  ## not the value moved.
  let id = nodeId(el)
  if not styleIsSet(id, prop, value):
    styleMemo[(id, prop)] = value
    r.setStyle(el, prop, value)

proc setStyleOnce*(r: GpuiRenderer; id: uint64; prop, value: string) =
  ## The same for the element a snapshot names (`SnapshotNode.id`): the
  ## element's handle is asked for only when there is something to write.
  if not styleIsSet(id, prop, value):
    let el = elementOf(id)
    if not el.isNil:
      styleMemo[(id, prop)] = value
      r.setStyle(el, prop, value)

# ---------------------------------------------------------------------------
# What a redraw built: the measure the tests and the frame report read
# ---------------------------------------------------------------------------

proc idWatermark*(): uint64 =
  ## A node id no element yet carries and every later one exceeds: the
  ## shim numbers its nodes in creation order, so the elements a redraw
  ## built are the ones whose id is above the watermark taken before it.
  let probe = gpui_create_element("div".cstring)
  result = nodeId(probe)
  gpui_destroy_tree(probe)

type
  PaneChurn* = object
    ## One pane's share of a redraw.
    pane*: string
    fresh*: int
      ## Elements in the pane built by the redraw.
    replaced*: int
      ## The pane's own children built by the redraw: the rows and overlays
      ## it replaced rather than kept.
    total*: int
      ## Elements in the pane after it.

  WindowChurn* = object
    fresh*, total*: int
    panes*: seq[PaneChurn]
    outside*: int
      ## Elements built outside every pane: the top bar, the footer, the
      ## strips, the scrollbars drawn over the panes.
    outsideRoots*: seq[string]
      ## Each subtree built outside the panes, named by its root's first
      ## attribute (or "-"), for a reader asking what else a step built.

proc churnSince*(root: GpuiElement; watermark: uint64;
                 panes: openArray[(string, GpuiElement)]): WindowChurn =
  ## What the window under `root` holds that was built after `watermark`,
  ## in all and per pane (`panes`: each pane's name and element).
  let nodes = snapshotTree(root)
  var paneOfId: Table[uint64, int]
  for k, (name, el) in panes:
    result.panes.add PaneChurn(pane: name)
    if not el.isNil:
      paneOfId[nodeId(el)] = k
  var paneAt = newSeq[int](nodes.len)
  var paneRootAt = newSeq[bool](nodes.len)
  for i, n in nodes:
    paneAt[i] = paneOfId.getOrDefault(n.id, -1)
    if paneAt[i] >= 0:
      paneRootAt[i] = true
    elif n.parent >= 0:
      paneAt[i] = paneAt[n.parent]
    let fresh = n.id > watermark
    inc result.total
    if fresh: inc result.fresh
    let p = paneAt[i]
    if p < 0 and fresh:
      inc result.outside
      if n.parent < 0 or nodes[n.parent].id <= watermark:
        result.outsideRoots.add(
          if n.attributes.len > 0: n.attributes[0][0] & "=" & n.attributes[0][1]
          else: "-")
    if p >= 0 and not paneRootAt[i]:
      inc result.panes[p].total
      if fresh:
        inc result.panes[p].fresh
        if n.parent >= 0 and paneRootAt[n.parent]:
          inc result.panes[p].replaced

var attributeMemo: Table[(uint64, string), string]
  ## The value each `setAttributeOnce` last gave an element's attribute.

proc setAttributeOnce*(r: GpuiRenderer; el: GpuiElement; name, value: string) =
  ## `r.setAttribute(el, name, value)` unless this is the value it was last
  ## given through here: a kept row whose position moved (an event row after
  ## the log scrolled) has that one attribute updated in place, and a row
  ## whose position did not move is not written.
  let key = (nodeId(el), name)
  if attributeMemo.getOrDefault(key, "\0") != value:
    attributeMemo[key] = value
    r.setAttribute(el, name, value)
