## test_golden_layout_hit.nim — PLAT-51 deliverable 10 (Layout-ViewModel
## §4.2.2): THE DROP ZONES ARE GOLDENLAYOUT'S, PORTED — the shared rules
## `headless_app/golden_layout_hit` and their model half in
## `headless_app/layout_interaction` (`dragLayoutFor`, `goldenStackPaths`,
## `goldenDropOf`, `targetOfGolden`), each case stated against golden-layout
## 2.6.0's own source (`node_modules/golden-layout/src/ts/`):
##
##   * `calculateItemAreas`: the ground's four 50 px side areas (top, left,
##     bottom, right — `oppositeSides`' key order), none when the root is a
##     stack, then per stack its element and its header;
##   * `getArea`: half-open containment, the SMALLEST surface, the first on a
##     tie;
##   * `Stack.getArea` / `highlightDropZone`: the left / top / right /
##     bottom hover areas, STRICT containment, a boundary point matching none
##     and leaving the previous segment;
##   * `highlightHeaderDropZone`: the insertion index from the tabs'
##     midpoints, the give-up left of the tabs, and the PLACEHOLDER that
##     shifts the tabs after it — so the answer depends on the sample before;
##   * the user's deviation: a smaller centred middle that JOINS, carved out
##     of top and bottom, and nothing else changed;
##   * the drag proxy: the dragged pane lifted out before anything is
##     measured, and the decision named back in panes so it commits against
##     the committed layout.
##
## The pointer-trace DIFFERENTIAL against the real Electron app — the same
## samples through GoldenLayout itself — is
## `tui/tests/test_plat51_dropzones_reference.nim` (it reads the capture's
## file). Pure: values in, values out; vm-unit and vm-unit-js. No mocks.

import std/[options, unittest]

import headless_app/layout_model
import headless_app/layout_interaction

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 76

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc stackAt(x, y, w, h: float; tabs: seq[float] = @[80.0];
             header = 30.0): GlStack =
  ## A stack drawn at (x, y), `w` x `h`, its header `header` tall, its tabs
  ## of the given widths from the header's left.
  result = GlStack(element: glRect(x, y, w, h),
                   header: glRect(x, y, w, header),
                   content: glRect(x, y + header, w, h - header))
  var tx = x
  for tw in tabs:
    result.tabs.add glRect(tx, y, tw, header)
    tx += tw

proc twoStacks(): GlGeometry =
  ## A row of two stacks over a 1000 x 600 ground.
  GlGeometry(ground: glRect(0, 0, 1000, 600), rootIsStack: false,
             placeholderPx: GlPlaceholderPx,
             stacks: @[stackAt(0, 0, 500, 600, @[80.0, 100.0]),
                       stackAt(500, 0, 500, 600, @[90.0])])

suite "PLAT-51: calculateItemAreas and getArea, ported":

  test "the side areas first (top, left, bottom, right), then element and header per stack":
    let g = twoStacks()
    let areas = glItemAreas(g)
    ck areas.len == 4 + 2 * 2
    ck areas[0].kind == gakSide and areas[0].side == gsTop
    ck areas[1].side == gsLeft and areas[2].side == gsBottom and
       areas[3].side == gsRight
    ck areas[0].rect == glRect(0, 0, 1000, GlSideAreaPx)
    ck areas[3].rect == GlRect(x1: 950, y1: 0, x2: 1000, y2: 600)
    ck areas[4].kind == gakStack and areas[4].stack == 0
    ck areas[5].kind == gakHeader and areas[5].stack == 0
    ck areas[5].surface == 500.0 * 30.0

  test "a root that is a stack lists no side areas":
    var g = twoStacks()
    g.rootIsStack = true
    g.stacks = @[g.stacks[0]]
    let areas = glItemAreas(g)
    ck areas.len == 2
    ck areas[0].kind == gakStack

  test "the SMALLEST surface under the point wins; x2 / y2 are outside":
    let g = twoStacks()
    let areas = glItemAreas(g)
    # Deep in the left stack's body: only its element.
    ck glAreaAt(areas, 250, 300) == 4
    # In the left band (50 x 600 = 30000) over the stack (500 x 600): band.
    ck glAreaAt(areas, 20, 300) == 1
    # On the left stack's header near the left edge: the header (500 x 30 =
    # 15000) beats the left band (30000).
    ck glAreaAt(areas, 20, 10) == 5
    # Below the header, where the top band (1000 x 50) and the left band
    # (50 x 600) overlap: the left, the smaller.
    ck glAreaAt(areas, 20, 40) == 1
    ck glAreaAt(areas, 300, 40) == 0
    # Half-open: x == x2 of the ground is in nothing.
    ck glAreaAt(areas, 1000, 300) == -1
    # A TIE of surfaces keeps the EARLIER area (`getArea`'s strict `<`).
    let tie = @[GlArea(kind: gakSide, side: gsTop, rect: glRect(0, 0, 10, 10),
                       surface: 100.0),
                GlArea(kind: gakSide, side: gsLeft, rect: glRect(0, 0, 10, 10),
                       surface: 100.0)]
    ck glAreaAt(tie, 5, 5) == 0

suite "PLAT-51: a stack's segments, ported (Stack.getArea / highlightDropZone)":

  test "left and right a quarter, top and bottom the middle column's halves":
    let s = stackAt(0, 0, 400, 430)   # content 400 x 400 from y 30
    ck glStackSegmentAt(s, 50, 200) == segLeft
    ck glStackSegmentAt(s, 350, 200) == segRight
    ck glStackSegmentAt(s, 200, 100) == segTop
    ck glStackSegmentAt(s, 200, 300) == segBottom
    # GoldenLayout has NO centre: the middle of the body is top or bottom.
    ck glStackSegmentAt(s, 200, 229) == segTop
    ck glStackSegmentAt(s, 200, 231) == segBottom
    ck glStackSegmentAt(s, 200, 10) == segHeader

  test "a boundary point matches no segment (strict), and leaves the last one":
    let s = stackAt(0, 0, 400, 430)
    ck glStackSegmentAt(s, 100, 200) == segNone      # x == x1 + w / 4
    var g = GlGeometry(ground: glRect(0, 0, 400, 430), rootIsStack: true,
                       placeholderPx: GlPlaceholderPx, stacks: @[s])
    let areas = glItemAreas(g)
    var st = glDragState(g)
    discard glPointerStep(g, areas, st, 50, 200)
    ck st.stacks[0].segment == segLeft
    let d = glPointerStep(g, areas, st, 100, 200)
    ck d.found and d.current and d.segment == segLeft

  test "an empty stack has one body segment":
    var s = stackAt(0, 0, 400, 430, @[])
    s.empty = true
    ck glStackSegmentAt(s, 200, 200) == segBody
    ck glStackSegmentAt(s, 50, 200) == segBody

  test "the user's smaller middle joins, and is carved out of top and bottom only":
    let s = stackAt(0, 0, 300, 330)   # content 300 x 300 from y 30
    ck glStackSegmentAt(s, 150, 170, NativeCentreShare) == segCentre
    ck glStackSegmentAt(s, 150, 170) == segTop          # GoldenLayout's own
    ck glStackSegmentAt(s, 150, 100, NativeCentreShare) == segTop
    ck glStackSegmentAt(s, 150, 280, NativeCentreShare) == segBottom
    ck glStackSegmentAt(s, 40, 180, NativeCentreShare) == segLeft
    ck glStackSegmentAt(s, 260, 180, NativeCentreShare) == segRight
    # The box is the middle third on both axes: smaller than PLAT-49's half.
    ck glStackSegmentAt(s, 99, 170, NativeCentreShare) == segTop
    ck glStackSegmentAt(s, 101, 170, NativeCentreShare) == segCentre
    ck NativeCentreShare < 0.5

suite "PLAT-51: the header's index and the placeholder, ported":

  test "left of a tab's middle before it, right of it after it; past the last, the end":
    let s = stackAt(0, 0, 500, 600, @[80.0, 100.0])
    ck glHeaderIndexAt(s, 10, -1, GlPlaceholderPx) == 0
    # Just left of the first tab's middle (40): still before it.
    ck glHeaderIndexAt(s, 35, -1, GlPlaceholderPx) == 0
    ck glHeaderIndexAt(s, 60, -1, GlPlaceholderPx) == 1
    ck glHeaderIndexAt(s, 100, -1, GlPlaceholderPx) == 1
    ck glHeaderIndexAt(s, 150, -1, GlPlaceholderPx) == 2
    ck glHeaderIndexAt(s, 400, -1, GlPlaceholderPx) == 2

  test "the placeholder shifts the tabs after it, so the answer depends on the sample before":
    let s = stackAt(0, 0, 500, 600, @[80.0, 100.0])
    # With the placeholder before tab 1, tab 1 is at 180..280.
    ck glTabRect(s, 1, 1, GlPlaceholderPx) == glRect(180, 0, 100, 30)
    # x 150 is in the gap the placeholder opened: over no tab, left of the
    # last one — GoldenLayout gives up and changes nothing.
    ck glHeaderIndexAt(s, 150, 1, GlPlaceholderPx) == -1
    ck glHeaderIndexAt(s, 190, 1, GlPlaceholderPx) == 1
    ck glHeaderIndexAt(s, 260, 1, GlPlaceholderPx) == 2

  test "a pointer step moves the one placeholder, and a body segment removes it":
    let g = twoStacks()
    let areas = glItemAreas(g)
    var st = glDragState(g)
    var d = glPointerStep(g, areas, st, 60, 10)
    ck d.segment == segHeader and d.headerIndex == 1
    ck st.placeholderStack == 0 and st.placeholderIndex == 1
    d = glPointerStep(g, areas, st, 520, 10)
    ck st.placeholderStack == 1 and st.placeholderIndex == 0
    d = glPointerStep(g, areas, st, 750, 300)
    ck st.placeholderStack == -1
    ck d.segment in {segTop, segBottom}

  test "a pointer over no area keeps the last valid decision (a gap, a splitter)":
    var g = twoStacks()
    g.stacks[1] = stackAt(510, 0, 490, 600)   # a 10 px gap at x 500..510
    let areas = glItemAreas(g)
    var st = glDragState(g)
    discard glPointerStep(g, areas, st, 400, 300)
    let d = glPointerStep(g, areas, st, 505, 300)
    ck d.found and not d.current
    ck d.area.kind == gakStack and d.area.stack == 0 and d.segment == segRight

  test "constrainDragToContainer: a pointer outside is put on the edge":
    let g = twoStacks()
    ck glClamp(g, -50, 300) == (0.0, 300.0)
    ck glClamp(g, 1200, 900) == (1000.0, 600.0)
    ck glClamp(g, 400, 300) == (400.0, 300.0)

suite "PLAT-51: the decision named in panes, committed against the committed layout":

  test "the drag proxy lifts the pane out before anything is measured":
    let l = initLayout(row([stack([pane(paneEditor), pane(paneState)]),
                            pane(paneCalltrace)]))
    let d = dragLayoutFor(l, paneState)
    ck d.tree.find(paneState).isNil
    ck not d.tree.find(paneEditor).isNil
    # A lone pane's stack goes, and the row it leaves collapses.
    let d2 = dragLayoutFor(l, paneCalltrace)
    ck d2.tree.find(paneCalltrace).isNil
    # The only pane of a layout cannot be lifted out.
    let lone = initLayout(pane(paneEditor))
    ck not dragLayoutFor(lone, paneEditor).tree.find(paneEditor).isNil

  test "every GoldenLayout stack, depth first: a stack, or a pane not in one":
    let l = initLayout(row([stack([pane(paneEditor), pane(paneState)]),
                            column([pane(paneCalltrace), pane(paneEventLog)])]))
    ck goldenStackPaths(l) == @["0", "1/0", "1/1"]

  test "a header index reorders within the stack the pane came from":
    let l = initLayout(row([stack([pane(paneEditor), pane(paneState),
                                   pane(paneEventLog)]),
                            pane(paneCalltrace)]))
    let shown = dragLayoutFor(l, paneEditor)
    # In the drag layout the stack is [state, event log]; index 2 = after both.
    let t = targetOfGolden(l, shown, paneEditor,
                           GoldenDrop(kind: gdHeader, stackPath: "0", index: 2))
    ck t.isSome and t.get.kind == dtIntoStack and t.get.index == 2
    let cmd = commandFor(l, paneEditor, t.get)
    ck cmd.isSome
    let after = apply(l, cmd.get)
    ck after.kind == loApplied
    let s = after.layout.tree.children[0]
    ck s.children[2].pane == paneEditor

  test "a segment splits the stack the pane is in; a side splits the root":
    let l = initLayout(row([stack([pane(paneEditor), pane(paneState)]),
                            pane(paneCalltrace)]))
    let shown = dragLayoutFor(l, paneCalltrace)
    let t = targetOfGolden(l, shown, paneCalltrace,
                           GoldenDrop(kind: gdSplit, edge: leBottom,
                                      stackPath: ""))
    ck t.isSome and t.get.kind == dtSplitAfter and t.get.axis == saColumn
    let r = targetOfGolden(l, shown, paneCalltrace,
                           GoldenDrop(kind: gdRootSide, edge: leLeft))
    ck r.isSome and r.get.kind == dtSplitRoot and r.get.edge == leLeft

  test "the middle joins after the last tab; nothing is no target":
    let l = initLayout(row([stack([pane(paneEditor), pane(paneState)]),
                            pane(paneCalltrace)]))
    let shown = dragLayoutFor(l, paneCalltrace)
    let t = targetOfGolden(l, shown, paneCalltrace,
                           GoldenDrop(kind: gdCentre, stackPath: ""))
    ck t.isSome and t.get.kind == dtIntoStack and t.get.index == 2
    ck targetOfGolden(l, shown, paneCalltrace,
                      GoldenDrop(kind: gdNone)).isNone

  test "a decision is named from GoldenLayout's area and the stack's paths":
    let paths = @["0", "1"]
    let side = GlDecision(found: true, current: true,
                          area: GlArea(kind: gakSide, side: gsRight))
    ck goldenDropOf(side, paths).kind == gdRootSide
    ck goldenDropOf(side, paths).edge == leRight
    let hdr = GlDecision(found: true, current: true,
                         area: GlArea(kind: gakHeader, stack: 1),
                         segment: segHeader, headerIndex: 0)
    ck goldenDropOf(hdr, paths) == GoldenDrop(kind: gdHeader, stackPath: "1",
                                             index: 0)
    let gaveUp = GlDecision(found: true, current: true,
                            area: GlArea(kind: gakStack, stack: 0),
                            segment: segHeader, headerIndex: -1)
    ck goldenDropOf(gaveUp, paths).kind == gdNone
    ck goldenDropOf(GlDecision(found: false), paths).kind == gdNone

suite "PLAT-51: assertion count":
  test "assertion count":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
