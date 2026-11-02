## test_plat70i_table_fit.nim — PLAT-70 Part I (Horizontal-Overflow.md §5.5),
## the SHARED decision every front-end lays its table panes out from
## (`viewmodels/table_fit`, the Event Log's declaration in `event_log_vm`),
## swept rather than sampled:
##
##   * §5.5.2's three modes over random tables and every pane width from 0 to
##     `needPref + 20`: FIT iff the preferred widths fit (every column at
##     least preferred, the slack only on flex columns, the pane filled when
##     one exists), SHRINK iff only the floors fit (every column between its
##     floor and its preferred width, the pane filled exactly), SCROLL
##     otherwise (every column at its floor, the table wider than the pane)
##     — HO-11, HO-12;
##   * monotonicity: one cell more never narrows a column (HO-12);
##   * a user's width is kept in every mode (HO-14), a never-cut column never
##     narrower than preferred, a fixed part exactly its width;
##   * the horizontal view over the fit: the bar only in SCROLL, `leftCol`
##     back to 0 when the bar goes (§4.1);
##   * the composite columns (§5.5.3): the Call Trace's floor is the deepest
##     row's indent + its name (capped) + `…`; a long argument list does not
##     raise it; the `name: value` rows' floor;
##   * the Event Log's declaration: the visible columns in order, numbers
##     never cut and at least their defaults, the output the one flex column,
##     a user width as `userUnits` in the caller's units.
##
## No mocks: pure values. Runs on the C and the JS backends.

import std/[random, unittest]

import ../../viewmodels/table_fit
import ../../viewmodels/event_log_vm

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 50

proc randomColumns(rng: var Rand): seq[FitColumn] =
  for i in 0 ..< rng.rand(1 .. 6):
    var c = FitColumn(name: "c" & $i,
                      minUnits: rng.rand(0 .. 15),
                      preferredUnits: rng.rand(0 .. 40),
                      flex: (if rng.rand(3) == 0: rng.rand(1 .. 3) else: 0),
                      neverCut: rng.rand(5) == 0)
    if rng.rand(6) == 0: c.userUnits = rng.rand(3 .. 20)
    if rng.rand(8) == 0: c.fixed = true
    result.add c

suite "PLAT-70 Part I: fit or scroll (§5.5.2)":

  test "the three modes' equations, swept (HO-11, HO-12, HO-14)":
    var rng = initRand(70_9)
    var bad = 0
    var modesSeen: set[FitMode]
    for trial in 0 ..< 300:
      let cols = randomColumns(rng)
      let gap = rng.rand(0 .. 2)
      let probe = fitTable(cols, 0, gap)
      var last: TableFit
      for vp in 0 .. probe.needPref + 20:
        let f = fitTable(cols, vp, gap)
        modesSeen.incl f.mode
        var sum = 0
        for w in f.widths: sum += w
        let content = sum + gap * (cols.len - 1)
        if content != f.contentUnits: inc bad
        var anyFlex = false
        for i, c in cols:
          let w = f.widths[i]
          if c.userUnits > 0 and w != c.userUnits: inc bad          # HO-14
          if c.fixed and c.userUnits <= 0 and w != max(0, c.preferredUnits): inc bad
          if w < c.floorOf: inc bad                                  # never below the floor
          if c.flex > 0 and c.userUnits <= 0 and not c.fixed: anyFlex = true
        case f.mode
        of fmFit:
          if f.needPref > vp: inc bad
          for i, c in cols:
            if f.widths[i] < c.preferredOf: inc bad                   # nothing cut
            if f.widths[i] > c.preferredOf and
               (c.flex <= 0 or c.userUnits > 0 or c.fixed): inc bad   # slack: flex only
          if anyFlex and content != vp: inc bad
          if not anyFlex and content != f.needPref: inc bad
        of fmShrink:
          if not (f.needMin <= vp and vp < f.needPref): inc bad
          for i, c in cols:
            if f.widths[i] > c.preferredOf: inc bad
          if content != vp: inc bad                                   # filled exactly
        of fmScroll:
          if f.needMin <= vp: inc bad                                 # HO-11
          for i, c in cols:
            if f.widths[i] != c.floorOf: inc bad
          if content <= vp: inc bad
        if f.overflows != (f.mode == fmScroll): inc bad
        # Monotone: one cell more never narrows a column (HO-12).
        if vp > 0:
          for i in 0 ..< cols.len:
            if f.widths[i] < last.widths[i]: inc bad
        last = f
    ck bad == 0
    ck modesSeen == {fmFit, fmShrink, fmScroll}

  test "a worked table: tick, kind, output":
    let cols = @[
      FitColumn(name: "tick", preferredUnits: 8, neverCut: true),
      FitColumn(name: "kind", preferredUnits: 4, neverCut: true),
      FitColumn(name: "out", minUnits: 12, preferredUnits: 30, flex: 1)]
    # needPref = 8 + 4 + 30 + 2 gaps = 44; needMin = 8 + 4 + 12 + 2 = 26.
    let fit = fitTable(cols, 60)
    ck fit.mode == fmFit
    ck fit.widths == @[8, 4, 46]
    ck fit.starts == @[0, 9, 14]
    let shrink = fitTable(cols, 30)
    ck shrink.mode == fmShrink
    ck shrink.widths == @[8, 4, 16]
    let scroll = fitTable(cols, 25)
    ck scroll.mode == fmScroll
    ck scroll.widths == @[8, 4, 12]
    ck scroll.contentUnits == 26
    # Exactly at the edges.
    ck fitTable(cols, 44).mode == fmFit
    ck fitTable(cols, 43).mode == fmShrink
    ck fitTable(cols, 26).mode == fmShrink
    ck fitTable(cols, 26).widths == @[8, 4, 12]

  test "a user's width is fixed, and can bring the bar (HO-14)":
    var cols = @[
      FitColumn(name: "a", minUnits: 5, preferredUnits: 10),
      FitColumn(name: "b", minUnits: 5, preferredUnits: 10, flex: 1,
                userUnits: 40)]
    let f = fitTable(cols, 30)
    ck f.mode == fmScroll
    ck f.widths == @[5, 40]
    let wide = fitTable(cols, 100)
    ck wide.mode == fmFit
    ck wide.widths == @[10, 40]      # the user's column takes no slack
    cols[1].userUnits = 0
    ck fitTable(cols, 100).widths == @[10, 89]

  test "the horizontal view over the fit: the bar only in SCROLL":
    let cols = @[FitColumn(name: "x", minUnits: 30, preferredUnits: 50,
                           flex: 1)]
    var v = HorizontalView()
    v.settle(fitTable(cols, 20))
    ck v.barShown(fitTable(cols, 20))
    ck v.contentCols == 30 and v.viewportCols == 20
    discard v.scrollBy(6)
    ck v.leftCol == 6
    discard v.scrollBy(100)
    ck v.leftCol == 10                 # at most content − viewport
    # Widened so the floor fits: the bar goes and the view returns to 0.
    v.settle(fitTable(cols, 40))
    ck not v.barShown(fitTable(cols, 40))
    ck v.leftCol == 0
    ck not v.overflows

suite "PLAT-70 Part I: composite columns (§5.5.3)":

  test "the Call Trace's floor: the deepest indent + name + …":
    let shallow = callFitRow(2, 4, 60)            # `main #1(a=…, …)`
    let deep = callFitRow(40, 10, 14)
    ck shallow.floorUnits == 2 + 4 + 1
    ck shallow.wholeUnits == 62
    ck deep.floorUnits == 40 + 10 + 1
    let col = compositeColumn([shallow, deep], "call")
    ck col.minUnits == 51
    ck col.preferredUnits == 62
    # The pane fits the floors: no bar, the rows cut at the pane.
    let f = compositeFit([shallow, deep], 55)
    ck f.mode == fmShrink
    ck f.compositeWidth == 55
    # A pane narrower than the deep row's indent and name: SCROLL.
    let s = compositeFit([shallow, deep], 45)
    ck s.mode == fmScroll
    ck s.compositeWidth == 51
    # Wide enough for every whole row: FIT, nothing cut.
    let w = compositeFit([shallow, deep], 80)
    ck w.mode == fmFit and w.compositeWidth == 80

  test "a long argument list does not raise the floor; a long name is capped":
    ck callFitRow(2, 4, 4000).floorUnits == 7
    ck callFitRow(0, 300, 300).floorUnits == CallNameFloorCells + 1
    ck callFitRow(0, 5, 5).floorUnits == 5      # nothing follows: no `…`
    # In pixels: the unit scales the cells, not the indent.
    ck callFitRow(16, 4, 10, unit = 9).floorUnits == 16 + 36 + 9

  test "the name: value rows' floor":
    let r = variableFitRow(30, 40)
    ck r.floorUnits == 30 + VariableValueFloorCells + 1
    ck variableFitRow(30, 6).floorUnits == 36    # a short value: itself

suite "PLAT-70 Part I: the Event Log's declaration (§5.5.3)":

  test "visible columns, numbers never cut, the output the flex column":
    var c = defaultEventLogColumns()
    var widest: array[EventLogColumn, int]
    widest[elcTick] = 11
    widest[elcIndex] = 2
    widest[elcOutput] = 70
    widest[elcLocation] = 30
    let cols = c.eventLogFitColumns(widest, eventLogDefaultCells())
    ck cols.len == c.visibleColumns.len
    ck cols[0].name == $c.visibleColumns[0]
    var flexes = 0
    for f in cols:
      if f.flex > 0: inc flexes
      if f.name == $elcTick:
        ck f.neverCut and f.preferredUnits == 11
      if f.name == $elcIndex:
        ck f.preferredUnits == EventLogIndexCells     # at least the default
      if f.name == $elcOutput:
        ck f.minUnits == EventLogOutputMinCells and f.preferredUnits == 70
    ck flexes == 1
    discard c.setColumnWidth(elcOutput, 20)
    let px = c.eventLogFitColumns(widest, eventLogDefaultCells(), unit = 9,
                                  userUnit = 8)
    for f in px:
      if f.name == $elcOutput:
        ck f.userUnits == 160 and f.minUnits == EventLogOutputMinCells * 9
    # The location column, when shown, has its own floor.
    discard c.showColumn(elcLocation)
    for f in c.eventLogFitColumns(widest, eventLogDefaultCells()):
      if f.name == $elcLocation:
        ck f.minUnits == EventLogLocationMinCells and f.flex == 0

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
