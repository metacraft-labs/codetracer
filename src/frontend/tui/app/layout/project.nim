## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/layout/project.nim — CTUI-3. `LayoutNode` -> Yoga -> integer cells.
##
## ## What this is, and what it is emphatically not
##
## It is a PROJECTION. `headless_app/layout_model.LayoutNode` already exists,
## already carries `pane` / `row` / `column` / `stack`, `activate`, `setWeight`,
## `validate` and JSON persistence, and is already what a replay session
## persists. This module gives that tree cell coordinates. It does not own a
## second layout model, and the day it starts to would be the day the TUI and
## the desktop stop agreeing about what a saved layout means.
##
## ## THE TREE REALLY GOES THROUGH YOGA
##
## Every container becomes a Yoga node through `isonim_tui`'s `TerminalLayout`
## (which wraps `isonim/layout/layout_engine`, which wraps Facebook Yoga), with
## `flex-direction` from the node's kind and `flex` from its `weight`. That is
## what makes `weight` mean the same thing here as it does in a desktop
## GoldenLayout config: a relative share of the parent's axis, divided by
## whatever engine is dividing.
##
## ## BUT THE CELL SNAP IS THIS MODULE'S, AND THAT IS DELIBERATE
##
## Not because isonim-tui's snap is broken. IT IS NOT, AND THIS COMMENT USED TO
## SAY OTHERWISE ON THE STRENGTH OF A MEASUREMENT NOBODY TOOK. What was
## actually measured, against the real `profileLayout` trees through
## `isonim_tui`'s own `TerminalLayout`:
##
##   * Compact 80x24, body 22 rows, split 3:1 — Yoga's RAW heights are
##     22.000 / 17.000 / 5.000, and `calculateLayoutInCells` returns the top row
##     as rows 0..16 and the stack as rows 17..21. Abutting. No overlap, and no
##     `16.5` anywhere: Yoga rounds to the pixel grid, `pointScaleFactor`
##     defaults to 1, and neither `isonim` nor `isonim-tui` ever calls
##     `YGConfigSetPointScaleFactor` — so every raw this code can read back is a
##     whole number.
##   * Over the same 609 terminal sizes the sweep in
##     `app/tests/test_layout_node_projection.nim` walks,
##     `calculateLayoutInCells` reports 0 overlapping cells, 0 uncovered cells
##     and 0 outsiders — and its rectangles are IDENTICAL to this module's at
##     every one of the 609.
##
## So what is the local snap for? For not depending on that. `snapTreeAt` sizes
## a child on the MAIN axis by a largest-remainder distribution against the
## parent's snapped extent (which sums exactly, by construction) but on the
## CROSS axis by `snapTotal` — `ceil` of the child's own raw float, with no
## clamp to the parent. `ceil` of a fractional raw can exceed its parent, and a
## nested tree would then overlap. Nothing makes those raws fractional TODAY;
## a point scale factor other than 1 would, and this module cannot see or
## control the config that decides it. (Recorded as a hardening follow-up
## against isonim-tui in CodeTracer-TUI.milestones.org — a clamp, not a fix for
## a live defect.)
##
## CTUI-3 asks for exactly the property that removes the dependency
## ("disjointness and totality are checked over the cell grid, not over Yoga's
## floats, because cell-snap rounding is where overlap is introduced"), so this
## module reads Yoga's FLOATS (`rawLayout`) — those stay the proportion, which
## is what keeps `weight` meaning what a GoldenLayout config means by it — and
## snaps top-down against the parent's ALREADY-SNAPPED integer extent:
##
##   * children's sizes on the main axis are a largest-remainder distribution
##     of the parent's integer size, so they sum to it EXACTLY;
##   * each child gets the parent's full extent on the cross axis, so a child
##     can never exceed its parent whatever the floats are;
##   * offsets chain end to end from the parent's origin.
##
## Under those three rules totality and disjointness hold BY CONSTRUCTION at
## any point scale factor, and `coverageProblems` below re-derives them from
## the returned rectangles over an actual cell grid — so the test is checking
## the output rather than trusting the argument.
##
## ## A LAYOUT THAT FAILS `validate` IS NEVER DRAWN AS IF IT WERE FINE
##
## CTUI-3: "a layout that fails `LayoutNode.validate` is a panic in debug and a
## degraded single-pane fallback in release, never a silently misdrawn screen".
## `ProjectionPolicy` is that rule, and `DefaultProjectionPolicy` is the
## build-configuration half of it. It is a PARAMETER rather than a bare `when`
## so both arms are reachable from one test binary; a release-only branch is a
## branch nothing in the fast lane can execute, and this one is the safety net.
##
## The two failure families are kept apart, because they have different causes
## and different right answers:
##
##   * a STRUCTURAL defect (`prInvalidLayout`) is a programming error — a tree
##     nobody should have built — and panics in debug;
##   * TOO LITTLE ROOM (`prNoSpace`) is an ordinary runtime condition — a user
##     dragged their terminal to 30x8 — and degrades in every configuration.
##     Panicking on it would turn a small window into a crash.

import std/[algorithm, math, strutils, tables]

import isonim_tui

import headless_app/layout_model

import ./profile

type
  PaneRegion* = object
    ## One visible pane and the cells it owns.
    pane*: PaneKind
    title*: string
      ## The `LayoutNode`'s own title, carried through so a view does not have
      ## to look the pane up again in a second table.
    area*: CellArea
    tabs*: seq[string]
      ## The titles of every tab in the enclosing `stack`, in order, when this
      ## pane sits in one; empty otherwise. This is what lets a view draw the
      ## Compact profile's `[Variables] Timeline Tracepoints` strip without
      ## walking the tree a second time.
    activeTab*: int
      ## Index into `tabs`, or -1 when the pane is not stacked.

  ProjectionStatus* = enum
    ## Why a projection is what it is.
    prOk = "ok"
    prInvalidLayout = "invalid-layout"
      ## `LayoutNode.validate` reported at least one problem.
    prNoSpace = "no-space"
      ## The area cannot hold one cell per visible pane along some axis.
    prEmptyLayout = "empty-layout"
      ## Nil, or a tree with no visible pane at all.

  ProjectionPolicy* = enum
    ## What to do about a STRUCTURALLY invalid tree. See the module header.
    ppPanic
      ## Raise `LayoutProjectionDefect`, naming every problem `validate` found.
    ppDegrade
      ## Fall back to a single pane covering the whole area, with
      ## `status == prInvalidLayout` so a caller can say so on screen.

  LayoutProjectionDefect* = object of Defect
    ## A tree that failed `validate` reached the renderer. A `Defect` rather
    ## than a `CatchableError` on purpose: this is a programming error, and an
    ## `except CatchableError` somewhere up the stack must not turn it into a
    ## degraded screen that looks deliberate.

  Projection* = object
    ## The result of projecting one `LayoutNode` onto one area.
    area*: CellArea
    regions*: seq[PaneRegion]
    status*: ProjectionStatus
    problems*: seq[LayoutProblem]
      ## Whatever `validate` said, carried so a report can name it.

  CoverageProblemKind* = enum
    ## Every way a set of pane regions can fail to be a faithful partition of
    ## an area. Enumerated rather than reported as prose for the reason
    ## `LayoutProblemKind` is: a test branches on the kind.
    cpEmptyRegion = "EmptyRegion"
      ## A visible pane with no cells. It would be invisible on screen while
      ## still being "laid out", which is the worst of both.
    cpOutsideArea = "OutsideArea"
      ## A region reaching beyond the area it was projected into.
    cpOverlap = "Overlap"
      ## Two panes claiming the same cell. The rounding failure mode.
    cpUncovered = "Uncovered"
      ## A cell in the area that no pane owns. It would paint as stale.

  CoverageProblem* = object
    ## One defect, with the coordinates that make it findable.
    kind*: CoverageProblemKind
    pane*: PaneKind
      ## The pane the problem is ABOUT — for `cpEmptyRegion`, `cpOutsideArea`
      ## and `cpOverlap`.
      ##
      ## FOR `cpUncovered` THERE IS NO SUCH PANE, and this field is a
      ## placeholder: an uncovered cell belongs to nobody, so `coverageProblems`
      ## fills it with `PaneKind.low`, which `$`-prints as `editor` — a real
      ## pane name. `describe` never reads it for that kind, and nothing should:
      ## `p.pane == paneEditor` on an `Uncovered` problem is true for free, at
      ## every geometry, forever (Verification-Harness-Traps §5 — a sentinel
      ## that collides with a legitimate value). A sentinel member is NOT the
      ## fix: `PaneKind` is `headless_app/layout_model`'s, it is persisted as
      ## JSON by the desktop, and widening it for a checker's convenience would
      ## change a saved-layout format. Read `row` / `col` / `cells` instead —
      ## which is what the mutation arms in
      ## `app/tests/test_layout_node_projection.nim` do.
    other*: PaneKind
      ## The second claimant, for `cpOverlap`. A placeholder for every other
      ## kind, on the same terms as `pane` above.
    row*: int
    col*: int
      ## Absolute screen coordinates of the offending cell; -1 when the problem
      ## is about a region rather than a cell.
    cells*: int
      ## How many cells share this problem — the size of the overlap or of the
      ## hole. "One cell differs" and "half the screen is missing" must not be
      ## the same report.

const
  DefaultProjectionPolicy* = when defined(release): ppDegrade else: ppPanic
    ## CTUI-3's rule, resolved at compile time. Asserted in
    ## `app/tests/test_layout_node_projection.nim` so a build that quietly
    ## flipped it is caught by the suite rather than by a user.

proc `$`*(a: CellArea): string =
  "(" & $a.col & "," & $a.row & " " & $a.width & "x" & $a.height & ")"

proc contains*(a: CellArea; row, col: int): bool =
  ## Whether the absolute cell `(row, col)` is inside `a`.
  row >= a.row and row < a.row + a.height and
  col >= a.col and col < a.col + a.width

proc cellCount*(a: CellArea): int =
  max(0, a.width) * max(0, a.height)

proc describe*(p: CoverageProblem): string =
  ## One line naming the kind, the pane(s) and the cell. "The regions do not
  ## partition the area" is not a diagnosis and this never emits one.
  case p.kind
  of cpEmptyRegion:
    "EmptyRegion: pane '" & $p.pane & "' was given no cells"
  of cpOutsideArea:
    "OutsideArea: pane '" & $p.pane & "' reaches outside the body area (" &
      $p.cells & " cell(s), first at row " & $p.row & ", col " & $p.col & ")"
  of cpOverlap:
    "Overlap: panes '" & $p.pane & "' and '" & $p.other & "' both claim " &
      $p.cells & " cell(s), first at row " & $p.row & ", col " & $p.col
  of cpUncovered:
    "Uncovered: " & $p.cells & " cell(s) belong to no pane, first at row " &
      $p.row & ", col " & $p.col

proc describe*(ps: seq[CoverageProblem]): string =
  var parts: seq[string] = @[]
  for p in ps:
    parts.add describe(p)
  parts.join("; ")

# ---------------------------------------------------------------------------
# The cell-grid invariant checker
# ---------------------------------------------------------------------------

proc coverageProblems*(regions: seq[PaneRegion]; area: CellArea):
    seq[CoverageProblem] =
  ## Every way `regions` fails to be a faithful partition of `area`, checked
  ## OVER THE CELL GRID.
  ##
  ## Not over the rectangles: two rectangles can be compared arithmetically and
  ## still be wrong about a cell, and the milestone names cell-snap rounding as
  ## the place overlap comes from. So this stamps an owner into every cell of
  ## the area and reads the result back — which is also what makes the mutation
  ## arms in `app/tests/test_layout_node_projection.nim` possible: a region
  ## widened by one column produces exactly one column of `cpOverlap`, named.
  result = @[]
  if area.width <= 0 or area.height <= 0:
    for r in regions:
      result.add CoverageProblem(kind: cpOutsideArea, pane: r.pane,
                                 other: r.pane, row: r.area.row,
                                 col: r.area.col, cells: r.area.cellCount())
    return

  const Unowned = -1
  var owner = newSeq[int](area.width * area.height)
  for i in 0 ..< owner.len:
    owner[i] = Unowned

  # Overlaps are accumulated per (first claimant, second claimant) pair so that
  # a whole overlapping column is ONE problem with a cell count, rather than
  # one problem per cell — a report of 24 identical lines is a report nobody
  # reads to the end.
  var overlapFirst = initTable[(int, int), (int, int)]()
  var overlapCells = initTable[(int, int), int]()
  var outsideFirst = initTable[int, (int, int)]()
  var outsideCells = initTable[int, int]()

  for idx, r in regions:
    if r.area.width <= 0 or r.area.height <= 0:
      result.add CoverageProblem(kind: cpEmptyRegion, pane: r.pane,
                                 other: r.pane, row: r.area.row,
                                 col: r.area.col, cells: 0)
      continue
    for row in r.area.row ..< r.area.row + r.area.height:
      for col in r.area.col ..< r.area.col + r.area.width:
        if not area.contains(row, col):
          if idx notin outsideCells:
            outsideFirst[idx] = (row, col)
            outsideCells[idx] = 0
          outsideCells[idx] = outsideCells[idx] + 1
          continue
        let at = (row - area.row) * area.width + (col - area.col)
        if owner[at] == Unowned:
          owner[at] = idx
        else:
          let key = (owner[at], idx)
          if key notin overlapCells:
            overlapFirst[key] = (row, col)
            overlapCells[key] = 0
          overlapCells[key] = overlapCells[key] + 1

  var outsideKeys: seq[int] = @[]
  for k in outsideCells.keys:
    outsideKeys.add k
  sort(outsideKeys)
  for k in outsideKeys:
    let (row, col) = outsideFirst[k]
    result.add CoverageProblem(kind: cpOutsideArea, pane: regions[k].pane,
                               other: regions[k].pane, row: row, col: col,
                               cells: outsideCells[k])

  var overlapKeys: seq[(int, int)] = @[]
  for k in overlapCells.keys:
    overlapKeys.add k
  sort(overlapKeys, proc (a, b: (int, int)): int =
    if a[0] != b[0]: cmp(a[0], b[0]) else: cmp(a[1], b[1]))
  for k in overlapKeys:
    let (row, col) = overlapFirst[k]
    result.add CoverageProblem(kind: cpOverlap, pane: regions[k[0]].pane,
                               other: regions[k[1]].pane, row: row, col: col,
                               cells: overlapCells[k])

  var uncovered = 0
  var firstRow = -1
  var firstCol = -1
  for at in 0 ..< owner.len:
    if owner[at] == Unowned:
      inc uncovered
      if firstRow < 0:
        firstRow = area.row + at div area.width
        firstCol = area.col + at mod area.width
  if uncovered > 0:
    result.add CoverageProblem(kind: cpUncovered, pane: PaneKind.low,
                               other: PaneKind.low, row: firstRow,
                               col: firstCol, cells: uncovered)

proc coveredCells*(regions: seq[PaneRegion]; area: CellArea): int =
  ## How many DISTINCT cells of `area` the regions cover.
  ##
  ## The positive control for every "no problems" assertion written over
  ## `coverageProblems`: an empty region list produces no overlaps and no
  ## outsiders, and only this number moving proves the check looked at
  ## anything (Verification-Harness-Traps §4).
  if area.width <= 0 or area.height <= 0:
    return 0
  var seen = newSeq[bool](area.width * area.height)
  for r in regions:
    for row in r.area.row ..< r.area.row + r.area.height:
      for col in r.area.col ..< r.area.col + r.area.width:
        if area.contains(row, col):
          seen[(row - area.row) * area.width + (col - area.col)] = true
  for s in seen:
    if s:
      inc result

# ---------------------------------------------------------------------------
# Integer distribution — the snap rule, kept where it can be tested alone
# ---------------------------------------------------------------------------

proc distributeCells*(total: int; shares: openArray[float]): seq[int] =
  ## Split `total` cells among `shares.len` siblings in the given proportions.
  ##
  ## THREE PROPERTIES, all of them relied on by `projectLayout` and all of them
  ## asserted directly in `app/tests/test_layout_node_projection.nim`:
  ##
  ##   1. the result sums to `total` EXACTLY — no slack, no overflow;
  ##   2. every entry is at least 1 whenever `total >= shares.len`, so no
  ##      visible pane is ever given an empty rectangle;
  ##   3. it is deterministic — largest fractional remainder first, ties broken
  ##      by the lower index — so a resize that returns to a previous width
  ##      returns to the same columns, which is what `test_resize_reflow.nim`
  ##      means by "no coordinate drifts".
  ##
  ## Returns an empty seq when `total < shares.len`; the caller reports that as
  ## `prNoSpace` rather than handing back a zero-width pane.
  let n = shares.len
  result = @[]
  if n == 0 or total < n:
    return
  var sum = 0.0
  for s in shares:
    sum += max(0.0, s)
  var ideal = newSeq[float](n)
  if sum <= 0.0:
    for i in 0 ..< n:
      ideal[i] = float(total) / float(n)
  else:
    for i in 0 ..< n:
      ideal[i] = float(total) * max(0.0, shares[i]) / sum
  result = newSeq[int](n)
  var frac = newSeq[float](n)
  var assigned = 0
  for i in 0 ..< n:
    let f = int(floor(ideal[i]))
    result[i] = f
    frac[i] = ideal[i] - float(f)
    assigned += f
  var order: seq[int] = @[]
  for i in 0 ..< n:
    order.add i
  sort(order, proc (a, b: int): int =
    if frac[a] > frac[b] + 1e-9: -1
    elif frac[a] < frac[b] - 1e-9: 1
    else: cmp(a, b))
  var remaining = total - assigned
  var k = 0
  while remaining > 0:
    result[order[k mod n]] += 1
    dec remaining
    inc k
  # Lift every zero to one by taking a cell from the largest sibling. Runs at
  # most `n` times because `total >= n`, and it is what makes property 2 hold
  # for a share of 0.0 or for a weight so small that its ideal floors to
  # nothing — both of which a saved layout can contain.
  while true:
    var lowest = 0
    var highest = 0
    for i in 1 ..< n:
      if result[i] < result[lowest]: lowest = i
      if result[i] > result[highest]: highest = i
    if result[lowest] >= 1 or result[highest] <= 1:
      break
    result[lowest] += 1
    result[highest] -= 1

# ---------------------------------------------------------------------------
# The projection
# ---------------------------------------------------------------------------

proc degradedProjection(node: LayoutNode; area: CellArea;
                        status: ProjectionStatus;
                        problems: seq[LayoutProblem]): Projection =
  ## The single-pane fallback: one pane over the whole area, and a status that
  ## says why. Never an empty screen and never a partial one — a caller that
  ## renders this draws something the user can read a message in.
  result = Projection(area: area, regions: @[], status: status,
                      problems: problems)
  if area.width <= 0 or area.height <= 0:
    return
  var chosen = paneEditor
  let placed = allPanes(node)
  if placed.len > 0:
    chosen = placed[0]
  result.regions.add PaneRegion(pane: chosen, title: $chosen, area: area,
                                tabs: @[], activeTab: -1)

proc weightShare(n: LayoutNode): float =
  ## A node's share of its parent's axis. `layout_model` documents `0` as
  ## "equal share with the other zero-weighted siblings", and one is the
  ## neutral share, so that is what a zero becomes here.
  if n.isNil or n.weight <= 0.0: 1.0 else: n.weight

proc projectLayout*(node: LayoutNode; area: CellArea;
                    policy: ProjectionPolicy = DefaultProjectionPolicy):
    Projection =
  ## Project `node` onto `area`, honouring `weight`, a `stack`'s active index,
  ## and therefore `isVisible`.
  ##
  ## Every VISIBLE pane gets a non-empty rectangle; the rectangles are pairwise
  ## disjoint; and their union is `area` exactly. Panes on the inactive side of
  ## a stack get nothing at all, which is the same answer `visiblePanes` gives
  ## and the reason a shell need not load data for a tab nobody can see.
  result = Projection(area: area, regions: @[], status: prOk, problems: @[])
  if node.isNil:
    return degradedProjection(node, area, prEmptyLayout, @[])

  let problems = validate(node)
  if problems.len > 0:
    if policy == ppPanic:
      var parts: seq[string] = @[]
      for p in problems:
        parts.add $p.kind & "@'" & p.path & "'"
      raise newException(LayoutProjectionDefect,
        "the layout tree failed LayoutNode.validate and would have been drawn " &
        "as if it were sound: " & parts.join(", ") & ". Tree: " & $node)
    return degradedProjection(node, area, prInvalidLayout, problems)

  if area.width <= 0 or area.height <= 0:
    return degradedProjection(node, area, prNoSpace, @[])
  if visiblePanes(node).len == 0:
    return degradedProjection(node, area, prEmptyLayout, @[])

  # ---- The Yoga tree. One handle per node, allocated depth-first. ----------
  let layout = newTerminalLayout(area.width, area.height)
  var handles = initTable[int, LayoutNode]()
  var handleOf = initTable[int, int64]()
    ## identity of a LayoutNode -> its Yoga handle. Keyed by a walk index
    ## rather than by the ref itself, because two panes of the same kind cannot
    ## exist (validate rejects duplicates) but two CONTAINERS with identical
    ## contents can, and a ref-keyed table would be right while a
    ## structure-keyed one would not.
  var nextHandle: int64 = 1
  var walkIndex = 0

  proc addToYoga(n: LayoutNode; parent: int64): int =
    ## Register `n` (and, for a stack, only its active child) and return this
    ## node's walk index.
    let index = walkIndex
    inc walkIndex
    let handle = nextHandle
    inc nextHandle
    handles[index] = n
    handleOf[index] = handle
    layout.registerCellNode(handle)
    if parent >= 0:
      layout.childOf(parent, handle)
    else:
      layout.setStyle(handle, "width", $area.width)
      layout.setStyle(handle, "height", $area.height)
    layout.setStyle(handle, "flex", formatFloat(weightShare(n), ffDecimal, 4))
    case n.kind
    of lnPane:
      discard
    of lnRow:
      layout.setStyle(handle, "flex-direction", "row")
      for c in n.children:
        discard addToYoga(c, handle)
    of lnColumn:
      layout.setStyle(handle, "flex-direction", "column")
      for c in n.children:
        discard addToYoga(c, handle)
    of lnStack:
      # ONLY THE ACTIVE CHILD IS REGISTERED. A hidden tab has no geometry —
      # that is what makes `visiblePanes` and this projection the same answer,
      # rather than two answers that agree today.
      layout.setStyle(handle, "flex-direction", "column")
      if n.activeIndex >= 0 and n.activeIndex < n.children.len:
        discard addToYoga(n.children[n.activeIndex], handle)
    index

  let rootIndex = addToYoga(node, -1)
  layout.calculateLayoutInCells()

  # ---- The snap. Top-down, against the parent's integer extent. ------------
  var childIndices = initTable[int, seq[int]]()
  block:
    # Re-walk to record which walk indices are which node's children, in the
    # same order `addToYoga` registered them. Cheaper and clearer than
    # threading the answer out of the recursion above.
    var idx = 0
    proc collect(n: LayoutNode): int =
      let me = idx
      inc idx
      childIndices[me] = @[]
      case n.kind
      of lnPane:
        discard
      of lnRow, lnColumn:
        for c in n.children:
          childIndices[me].add collect(c)
      of lnStack:
        if n.activeIndex >= 0 and n.activeIndex < n.children.len:
          childIndices[me].add collect(n.children[n.activeIndex])
      me
    discard collect(node)

  var noSpace = false
  # A local rather than `result.regions`: Nim refuses to capture `result` in a
  # closure ("cannot be captured as it would violate memory safety"), and the
  # placement walk below is recursive, so it has to be one.
  var placed: seq[PaneRegion] = @[]

  proc place(index: int; where: CellArea; tabs: seq[string]; active: int) =
    let n = handles[index]
    case n.kind
    of lnPane:
      placed.add PaneRegion(pane: n.pane, title: n.title, area: where,
                            tabs: tabs, activeTab: active)
    of lnStack:
      # The active tab occupies the whole stack region; the tab strip is chrome
      # the VIEW draws inside that region, so the projection stays total.
      let kids = childIndices[index]
      if kids.len == 0:
        noSpace = true
        return
      var titles: seq[string] = @[]
      for c in n.children:
        titles.add(if c.title.len > 0: c.title else: $c.pane)
      place(kids[0], where, titles, n.activeIndex)
    of lnRow, lnColumn:
      let kids = childIndices[index]
      if kids.len == 0:
        noSpace = true
        return
      var shares: seq[float] = @[]
      for c in kids:
        let raw = layout.rawLayout(handleOf[c])
        # Yoga's FLOAT answer is the proportion; the integers come from
        # `distributeCells` against the parent's ALREADY-SNAPPED extent, so a
        # child's cells sum to its parent's exactly and the cross axis is the
        # parent's own. Measured, isonim-tui's `calculateLayoutInCells` returns
        # the same rectangles at all 609 geometries the sweep in
        # `app/tests/test_layout_node_projection.nim` walks — see the module
        # header for why this module snaps anyway rather than leaning on that
        # agreement.
        shares.add(if n.kind == lnRow: raw.width else: raw.height)
      let axis = if n.kind == lnRow: where.width else: where.height
      let sizes = distributeCells(axis, shares)
      if sizes.len == 0:
        noSpace = true
        return
      var cursor = if n.kind == lnRow: where.col else: where.row
      for i, c in kids:
        let sub =
          if n.kind == lnRow:
            CellArea(col: cursor, row: where.row, width: sizes[i],
                     height: where.height)
          else:
            CellArea(col: where.col, row: cursor, width: where.width,
                     height: sizes[i])
        cursor += sizes[i]
        place(c, sub, tabs, active)

  place(rootIndex, area, @[], -1)
  layout.dispose()

  if noSpace:
    return degradedProjection(node, area, prNoSpace, @[])
  result.regions = placed

proc regionFor*(p: Projection; kind: PaneKind): CellArea =
  ## The cells `kind` owns, or a zero area when it is not visible.
  for r in p.regions:
    if r.pane == kind:
      return r.area
  CellArea()

proc visiblePaneKinds*(p: Projection): seq[PaneKind] =
  result = @[]
  for r in p.regions:
    result.add r.pane

proc describe*(p: Projection): string =
  ## A one-line rendering for a failure message: the status, the area, and
  ## every pane with its rectangle.
  var parts: seq[string] = @[]
  parts.add $p.status & " over " & $p.area
  for r in p.regions:
    parts.add $r.pane & "=" & $r.area
  parts.join(" | ")
