## test_gpui_element_reuse.nim — what a kept element is, through the real shim.
##
## The window's redraws keep the elements that did not move
## (`element_reuse`): a piece drawn last time under the same key from the
## same digest is handed back instead of built, and whatever the last draw
## built and this one did not take is destroyed. A kept row keeps the
## listeners it was wired with, so those listeners must report what the row
## says when they fire, not what it said when they were wired
## (`window_clicks.wireOne`).
##
## No mocks: the real isonim-gpui shadow tree (the shim loaded in process, no
## window). The one stand-in is the click sink, a closure that records the
## clicks the window's listeners report; it is the seam the window itself
## passes (`onPaneClick`), not a model of anything.
##
## Run: `nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_gpui_element_reuse.nim`
## from the repo root, with isonim-gpui's shim on `LD_LIBRARY_PATH`.

import std/[hashes, strutils, unittest]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../element_reuse
import ../window_clicks
from ../../view_vocabulary/fact_reader import ViewIdAttribute

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const ExpectedAssertions = 23

let r = GpuiRenderer()

proc piece(tag: string): GpuiElement =
  let el = r.createElement(tag)
  r.appendChild(el, r.createTextNode(tag))
  el

proc alive(id: uint64): bool = not elementOf(id).isNil

suite "GPUI: a redraw keeps what did not move":

  setup:
    gpui_reset_tree()

  test "a piece drawn from the same digest is handed back, not built":
    var pool: ElementPool
    var builds = 0
    pool.begin()
    let first = pool.keyed("row:1", hash(1)):
      inc builds
      piece("div")
    pool.finish()
    let id = nodeId(first)
    pool.begin()
    let again = pool.keyed("row:1", hash(1)):
      inc builds
      piece("div")
    pool.finish()
    ck builds == 1
    ck nodeId(again) == id
    ck pool.reused == 1 and pool.built == 0

  test "a piece drawn from another digest is built, and the old one destroyed":
    var pool: ElementPool
    pool.begin()
    let first = pool.keyed("row:1", hash(1)): piece("div")
    pool.finish()
    let old = nodeId(first)
    pool.begin()
    let moved = pool.keyed("row:1", hash(2)): piece("span")
    pool.finish()
    ck nodeId(moved) != old
    ck not alive(old)
    ck alive(nodeId(moved))

  test "what a draw did not take is destroyed when it finishes":
    var pool: ElementPool
    pool.begin()
    let a = pool.keyed("a", hash(1)): piece("div")
    let b = pool.keyed("b", hash(1)): piece("div")
    pool.finish()
    # Ids, not handles: a destroyed node's handle names nothing any more.
    let (aId, bId) = (nodeId(a), nodeId(b))
    pool.begin()
    discard pool.keyed("a", hash(1)): piece("div")
    pool.finish()
    ck alive(aId)
    ck not alive(bId)

  test "a leftover something attached elsewhere is not destroyed":
    var pool: ElementPool
    let holder = r.createElement("div")
    pool.begin()
    let a = pool.keyed("a", hash(1)): piece("div")
    pool.finish()
    r.appendChild(holder, a)
    pool.begin()
    pool.finish()
    ck alive(nodeId(a))

  test "one key twice in one draw: the second is built, not the first taken":
    var pool: ElementPool
    pool.begin()
    let a = pool.keyed("a", hash(1)): piece("div")
    pool.finish()
    pool.begin()
    let first = pool.keyed("a", hash(1)): piece("div")
    let second = pool.keyed("a", hash(1)): piece("div")
    pool.finish()
    ck nodeId(first) == nodeId(a)
    ck nodeId(second) != nodeId(a)
    # And the pool still holds the first: the next draw takes it again.
    pool.begin()
    let third = pool.keyed("a", hash(1)): piece("div")
    pool.finish()
    ck nodeId(third) == nodeId(a)

  test "a style given through setStyleOnce is not written again":
    let el = r.createElement("div")
    r.setStyleOnce(el, "color", "#111111")
    # Changed behind the memo's back: a second `setStyleOnce` with the value
    # it already gave must not write, so the element keeps the other value.
    r.setStyle(el, "color", "#222222")
    r.setStyleOnce(el, "color", "#111111")
    ck renderPlanJson(r, el).contains("#222222")
    r.setStyleOnce(el, "color", "#333333")
    ck renderPlanJson(r, el).contains("#333333")

suite "GPUI: a kept row's listener reads the row as it is now":

  setup:
    gpui_reset_tree()

  proc eventLogRow(index: string): (GpuiElement, GpuiElement) =
    let pane = r.createElement("div")
    r.setAttribute(pane, ViewIdAttribute, "eventLog")
    let row = r.createElement("div")
    r.setAttribute(row, "data-row-index", index)
    r.appendChild(row, r.createTextNode("event"))
    r.appendChild(pane, row)
    (pane, row)

  proc press(el: GpuiElement): int =
    fireEvent(el, "mousedown", GpuiEvent(kind: gekPointerDown, key: "10,20,1"))

  test "the row's index moved after it was wired: the press reports the new one":
    var clicks: seq[GPaneClick]
    var dedupe: PressDedupe
    let (pane, row) = eventLogRow("3")
    var nodes = snapshotTree(pane)
    ck wireWindowClicks(r, nodes, addr dedupe,
                        proc(c: GPaneClick) = clicks.add c) == 1
    ck press(row) > 0
    ck clicks.len == 1 and clicks[0].part == gcpEventRow and
       clicks[0].index == 3
    # The row is kept by a redraw that moved it: its index is set in place.
    r.setAttribute(row, "data-row-index", "7")
    dedupe.clear()
    ck press(row) > 0
    ck clicks.len == 2 and clicks[^1].index == 7

  test "a row moved out of its pane reports nothing":
    var clicks: seq[GPaneClick]
    var dedupe: PressDedupe
    let (pane, row) = eventLogRow("1")
    var nodes = snapshotTree(pane)
    discard wireWindowClicks(r, nodes, addr dedupe,
                             proc(c: GPaneClick) = clicks.add c)
    let elsewhere = r.createElement("div")
    r.appendChild(elsewhere, row)
    discard press(row)
    ck clicks.len == 0

  test "control: a wired row's press reaches the sink at all":
    var clicks: seq[GPaneClick]
    var dedupe: PressDedupe
    let (pane, row) = eventLogRow("5")
    var nodes = snapshotTree(pane)
    discard wireWindowClicks(r, nodes, addr dedupe,
                             proc(c: GPaneClick) = clicks.add c)
    ck press(row) > 0
    ck clicks.len == 1

suite "GPUI: element reuse, the count":
  test "every assertion ran":
    ck CHECKS == ExpectedAssertions
