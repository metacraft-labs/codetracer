## viewmodels/table_fit.nim — how wide a TABLE pane's columns are, and whether
## the pane needs a horizontal bar: fit or scroll, from the columns' minimum
## and preferred widths.
##
## Spec: `codetracer-specs/spec/GUI/Layout-And-Navigation/Horizontal-Overflow.md`
## §5.5 (PLAT-70 Part I). The panes: Event Log, Variables, Call Trace.
##
## **The model is CSS's automatic table layout** (CSS 2.2 §17.5.2.2): every
## column declares a minimum and a preferred width (`FitColumn`), and
## `fitTable` lays the table out
##
##   * at the preferred widths when they fit, the slack shared by the flex
##     columns (`fmFit` — nothing is cut, no bar);
##   * between the floors and the preferred widths when only the floors fit,
##     shrinking each column in proportion to how much it can give
##     (`fmShrink` — the cells wider than their column are cut with `…` by
##     `table_overflow.fitCell`, no bar);
##   * at the floors, wider than the pane, when even they do not fit
##     (`fmScroll` — the pane draws §4's overflow-only horizontal bar, whose
##     model is `horizontal_scroll.HorizontalView` over `contentUnits`).
##
## A column the user resized (§5.2, `userUnits`) is fixed in every mode.
##
## **Units are the caller's.** The terminal lays out in cells, GPUI in pixels;
## the solver only adds and shares integers. A declaration helper takes the
## caller's units per CELL (`unit`) for the minimums, which the spec states in
## cells, so one declaration serves every front-end (HO-13: the same decision
## in each front-end's own units).
##
## Pure; C and JavaScript backends.

import ./horizontal_scroll

export horizontal_scroll

type
  FitMode* = enum
    fmFit = "fit"
      ## Every column at (at least) its preferred width.
    fmShrink = "shrink"
      ## Between the floors and the preferred widths; the pane is filled.
    fmScroll = "scroll"
      ## At the floors, wider than the pane: the horizontal bar is drawn.

  FitColumn* = object
    ## One column's declaration (§5.5.1), in the caller's units.
    name*: string
    minUnits*: int
      ## The narrowest it may be drawn before the pane scrolls instead. A
      ## column whose content is narrower needs only its content
      ## (`floorOf`).
    preferredUnits*: int
      ## Its max-content width over the rows the pane shows now.
    flex*: int
      ## Its share of the slack in `fmFit` (0: never wider than preferred).
    neverCut*: bool
      ## Never narrower than its preferred width (a number, a badge).
    userUnits*: int
      ## The width the user gave it (§5.2), > 0 when set: fixed in every mode.
    fixed*: bool
      ## A FIXED PART of a row rather than a column (the terminal Variables
      ## pane's tag, indent and controls): exactly `preferredUnits` wide in
      ## every mode, and no slack.

  TableFit* = object
    ## The decision, made once per frame and drawn by every front-end.
    mode*: FitMode
    widths*: seq[int]
      ## Each column's width, in declaration order.
    starts*: seq[int]
      ## Each column's first unit, from the table's left edge (the gap
      ## before it counted).
    gap*: int
    viewportUnits*: int
      ## What the pane gives its columns.
    contentUnits*: int
      ## How wide the laid-out table is: Σ widths + the gaps. Equal to
      ## `viewportUnits` in `fmShrink` and in `fmFit` with a flex column;
      ## wider than it exactly in `fmScroll`.
    needMin*, needPref*: int
      ## Σ floors + gaps and Σ preferred + gaps (§5.5.2).

func floorOf*(c: FitColumn): int =
  ## §5.5.2: the user's width, else the preferred width of a never-cut column
  ## (or a fixed part), else `min(minUnits, preferredUnits)`.
  if c.userUnits > 0: c.userUnits
  elif c.neverCut or c.fixed: max(0, c.preferredUnits)
  else: max(0, min(c.minUnits, c.preferredUnits))

func preferredOf*(c: FitColumn): int =
  if c.userUnits > 0: c.userUnits
  else: max(max(0, c.preferredUnits), c.floorOf)

func grows(c: FitColumn): bool =
  c.userUnits <= 0 and not c.fixed and c.flex > 0

proc shareByWeight(total: int; weights: openArray[int]): seq[int] =
  ## `total` shared in proportion to `weights` (each ≥ 0), one unit at a time
  ## to the column with the largest `weight / (share + 1)` (Jefferson's
  ## divisor rule; ties to the left-most). Built unit by unit, so one unit
  ## more never takes a unit from any column — the layout is MONOTONE in the
  ## pane's width (HO-12), which a largest-remainder share is not (its
  ## Alabama paradox). The shares sum to `total` when any weight is
  ## positive.
  result = newSeq[int](weights.len)
  var any = false
  for w in weights:
    if w > 0: any = true
  if not any or total <= 0:
    return
  for _ in 0 ..< total:
    var best = -1
    for i in 0 ..< weights.len:
      if weights[i] <= 0: continue
      # weights[i] / (result[i] + 1) > weights[best] / (result[best] + 1)
      if best < 0 or weights[i] * (result[best] + 1) >
                     weights[best] * (result[i] + 1):
        best = i
    inc result[best]

proc fitTable*(columns: openArray[FitColumn]; viewport: int;
               gap = 1): TableFit =
  ## §5.5.2: FIT, SHRINK or SCROLL, and every column's width.
  result.gap = max(0, gap)
  result.viewportUnits = max(0, viewport)
  let n = columns.len
  result.widths = newSeq[int](n)
  result.starts = newSeq[int](n)
  let gaps = result.gap * max(0, n - 1)
  var floors = newSeq[int](n)
  var prefs = newSeq[int](n)
  for i, c in columns:
    floors[i] = c.floorOf
    prefs[i] = c.preferredOf
    result.needMin += floors[i]
    result.needPref += prefs[i]
  result.needMin += gaps
  result.needPref += gaps
  let vp = result.viewportUnits
  if result.needPref <= vp:
    result.mode = fmFit
    var weights = newSeq[int](n)
    for i, c in columns:
      weights[i] = (if c.grows: c.flex else: 0)
    let extra = shareByWeight(vp - result.needPref, weights)
    for i in 0 ..< n:
      result.widths[i] = prefs[i] + extra[i]
  elif result.needMin <= vp:
    result.mode = fmShrink
    var room = newSeq[int](n)
    for i in 0 ..< n:
      room[i] = prefs[i] - floors[i]
    let given = shareByWeight(vp - result.needMin, room)
    for i in 0 ..< n:
      result.widths[i] = floors[i] + given[i]
  else:
    result.mode = fmScroll
    for i in 0 ..< n:
      result.widths[i] = floors[i]
  var at = 0
  for i in 0 ..< n:
    if i > 0: at += result.gap
    result.starts[i] = at
    at += result.widths[i]
  result.contentUnits = at

func overflows*(f: TableFit): bool =
  ## HO-11: the bar exists iff the floors do not fit.
  f.mode == fmScroll

func indexOf*(f: TableFit; columns: openArray[FitColumn]; name: string): int =
  for i, c in columns:
    if c.name == name: return i
  -1

proc settle*(v: var HorizontalView; f: TableFit) =
  ## The pane's horizontal view over this frame's decision: the content is
  ## the laid-out table while it scrolls and nothing past the pane otherwise,
  ## so the view returns to column 0 when the bar goes (§4.1) and stays
  ## inside the table while it is shown.
  v.setContent(if f.overflows: f.contentUnits else: 0)
  v.setViewport(f.viewportUnits)

func barShown*(v: HorizontalView; f: TableFit): bool =
  f.overflows and v.overflows

# ---------------------------------------------------------------------------
# Composite columns: one column whose cells are whole rows (§5.5.3)
# ---------------------------------------------------------------------------

const
  CallNameFloorCells* = 24
    ## §5.5.3: a callee name longer than this is not kept whole in the Call
    ## Trace's floor (it can still be cut).
  VariableValueFloorCells* = 8
    ## The value cells a `name: value` row keeps in its floor
    ## (the terminal's `MinimumValueCells`).

type
  CompositeRow* = object
    ## One row of a composite column, in the caller's units.
    floorUnits*: int
      ## What the row needs before the pane scrolls: its indent and the part
      ## that must stay whole.
    wholeUnits*: int
      ## The row's whole width: its indent and its whole text.

func compositeRow*(indentUnits, headUnits, wholeTextUnits: int;
                   ellipsisUnits: int): CompositeRow =
  ## A row whose first `headUnits` of text (a callee's or a variable's name,
  ## already capped by the caller) must stay whole, plus one `…` when more
  ## follows.
  let head = min(headUnits, wholeTextUnits)
  let more = if wholeTextUnits > head: ellipsisUnits else: 0
  CompositeRow(floorUnits: max(0, indentUnits) + head + more,
               wholeUnits: max(0, indentUnits) + max(0, wholeTextUnits))

func callFitRow*(indentUnits, calleeCells, textCells: int;
                 unit = 1): CompositeRow =
  ## §5.5.3, the Call Trace: indent + toggle (`indentUnits`, the cells
  ## before the row's text) + the callee's whole name up to
  ## `CallNameFloorCells` + 1 for the `…` when more follows. `calleeCells`
  ## and `textCells` are the name's and the row's whole text's widths in
  ## cells; `unit` is the caller's units per cell.
  compositeRow(indentUnits, min(calleeCells, CallNameFloorCells) * unit,
               textCells * unit, unit)

func variableFitRow*(fixedUnits, valueCells: int; unit = 1): CompositeRow =
  ## §5.5.3, Variables as `name: value` (GPUI, the desktop): the row's
  ## fixed parts (`fixedUnits`: indent, expander, the whole `name:`, the
  ## type and the controls — none of them cut) and the first
  ## `VariableValueFloorCells` of its value, plus a `…` when more follows;
  ## its preferred width the whole value (`valueCells` cells).
  compositeRow(fixedUnits, VariableValueFloorCells * unit, valueCells * unit,
               unit)

func compositeColumn*(rows: openArray[CompositeRow]; name: string;
                      flex = 1): FitColumn =
  ## §5.5.3: a composite column's floor and preferred width are the WIDEST
  ## over the rows shown — a deep row raises the floor by its indent.
  result = FitColumn(name: name, flex: flex)
  for r in rows:
    result.minUnits = max(result.minUnits, r.floorUnits)
    result.preferredUnits = max(result.preferredUnits, r.wholeUnits)

proc compositeFit*(rows: openArray[CompositeRow]; viewport: int;
                   name = "row"): TableFit =
  ## The one-column table of a composite pane.
  fitTable([compositeColumn(rows, name)], viewport, gap = 0)

func compositeWidth*(f: TableFit): int =
  ## The width a composite pane's rows are fitted to: the pane in FIT and
  ## SHRINK, the floor in SCROLL.
  if f.widths.len == 0: f.viewportUnits else: f.widths[0]

# ---------------------------------------------------------------------------
# The Test Results pane's row (PLAT-53, Test-Results-Pane.md §8.4)
# ---------------------------------------------------------------------------

const
  TestNameFlex* = 18
  TestWhereFlex* = 10
    ## The desktop's `grid-template-columns: 14px minmax(0, 1.8fr)
    ## minmax(0, 1fr) auto auto`: the name and the location share the room
    ## 1.8 : 1, whatever they hold — the name outranks the location
    ## (`styles/components/ns9_panes.styl`'s grid comment).
  TestColumnNames* = ["mark", "name", "where", "duration", "actions"]

proc testResultsFit*(markUnits, durationUnits, actionsUnits, viewport: int;
                     gap = 1): TableFit =
  ## The five columns' widths for a pane `viewport` units wide: the mark,
  ## the duration (never cut) and the actions at their widths, and the name
  ## and the location sharing what is left as the desktop's `fr` tracks do
  ## (`table_fit` with zero preferred widths: every unit of slack is shared
  ## by the flex weights).
  fitTable([
    FitColumn(name: TestColumnNames[0], preferredUnits: markUnits,
              fixed: true),
    FitColumn(name: TestColumnNames[1], flex: TestNameFlex),
    FitColumn(name: TestColumnNames[2], flex: TestWhereFlex),
    FitColumn(name: TestColumnNames[3], preferredUnits: durationUnits,
              neverCut: true),
    FitColumn(name: TestColumnNames[4], preferredUnits: actionsUnits,
              fixed: true)], viewport, gap)

# ---------------------------------------------------------------------------
# The Requests pane's row (PLAT-58, Request-Panel.md § N.1)
# ---------------------------------------------------------------------------

const
  RequestsColumnNames* = ["id", "method", "url", "status", "duration", "size"]
  RequestUrlFloorCells* = 8
    ## The URL keeps this many cells before the pane scrolls instead.

proc requestsFit*(idUnits, methodUnits, urlUnits, statusUnits, durationUnits,
                  sizeUnits, viewport: int; unit = 1; gap = 1): TableFit =
  ## The six columns' widths for a pane `viewport` units wide: `#`, the
  ## method, the status, the duration and the size at their widest cell (the
  ## header's word included) and never cut; the URL — the desktop's one
  ## `flex: 1` column, cut with `…` — takes the rest, keeping at least
  ## `RequestUrlFloorCells` before the pane scrolls.
  fitTable([
    FitColumn(name: RequestsColumnNames[0], preferredUnits: idUnits,
              neverCut: true),
    FitColumn(name: RequestsColumnNames[1], preferredUnits: methodUnits,
              neverCut: true),
    FitColumn(name: RequestsColumnNames[2], preferredUnits: urlUnits,
              minUnits: RequestUrlFloorCells * unit, flex: 1),
    FitColumn(name: RequestsColumnNames[3], preferredUnits: statusUnits,
              neverCut: true),
    FitColumn(name: RequestsColumnNames[4], preferredUnits: durationUnits,
              neverCut: true),
    FitColumn(name: RequestsColumnNames[5], preferredUnits: sizeUnits,
              neverCut: true)], viewport, gap)
