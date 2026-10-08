## headless_app/arrangement_relation.nim — PLAT-45. **The medium-independent
## relation three front-ends' arrangements are compared in.**
##
## PLAT-45's first real-stack test opens the same recording in the desktop, the
## GPUI window and the terminal and asks whether all three show the same panes
## in the same places. Each medium answers in its own units — DOM pixels with
## GoldenLayout's 4-pixel splitters between them, GPUI's dock document in its
## own pixels, terminal cells — and in its own rounding. So each is REDUCED,
## from its own output, to a relation that has no unit in it at all
## (PLAT-20's: pairwise BEFORE and stack membership), and only the reductions
## are compared.
##
## ## How rectangles become a relation without trusting proportions
##
## A relation read off coordinates pair by pair ("a ends left of where b
## starts") depends on the proportions: two regions in different columns whose
## horizontal edges happen to line up are "above" each other in one medium and
## not in another that rounded differently. The reduction here is instead the
## GUILLOTINE DECOMPOSITION every split-tree layout is: find every straight cut
## that crosses the whole area without entering a region (with a tolerance for
## a splitter or a rounding), split there, and recurse. What comes out is the
## row/column/tab structure itself — `row(stack[fileTree*,vcs],editor,…)` —
## which depends on WHICH region is beside which, never on how wide.
## `beforePairs` then reads BEFORE off that structure (the lowest common
## container decides: its axis says left/above, the child order says which).
##
## The same canonical form is produced from a `LayoutNode` by `ofTree`, which
## is what a test compares the three media AGAINST — the shared tree's relation
## is the expected value, and each medium's is measured.

import std/[algorithm, sets, strutils]

import layout_model

type
  RegionRect* = object
    ## One region a medium drew: where, and which panes it holds.
    x*, y*, w*, h*: float
    tabs*: seq[string]
      ## The panes of the region in tab order (one for an unstacked pane),
      ## spelled as `PaneKind` strings.
    active*: int
      ## Index into `tabs` of the visible one.

  ArrangementNode* = ref object
    ## The reconstructed structure. `axis` is "row", "column" or "" for a
    ## region.
    axis*: string
    children*: seq[ArrangementNode]
    region*: RegionRect

  Arrangement* = object
    canonical*: string
      ## The whole structure as one string: `row(…)`, `column(…)`, and each
      ## region as `stack[a*,b]` (the starred tab is the active one) or a bare
      ## pane name.
    before*: HashSet[string]
      ## `a<b` for every ordered pair of VISIBLE panes where `a` comes first
      ## along the axis of their lowest common container.
    groups*: seq[string]
      ## Every region's tab list with its active tab, sorted — stack
      ## membership.
    visible*: HashSet[string]
    problem*: string
      ## Non-empty when the rectangles are not a guillotine tiling (two
      ## regions overlap, or no cut separates them): the reduction refuses
      ## rather than inventing a structure.

proc regionText(r: RegionRect): string =
  if r.tabs.len == 1:
    return r.tabs[0]
  var parts: seq[string] = @[]
  for i, t in r.tabs:
    parts.add(if i == r.active: t & "*" else: t)
  "stack[" & parts.join(",") & "]"

proc canonicalOf(n: ArrangementNode): string =
  if n.axis.len == 0:
    return regionText(n.region)
  var parts: seq[string] = @[]
  for c in n.children:
    parts.add canonicalOf(c)
  n.axis & "(" & parts.join(",") & ")"

proc cutsAlong(rects: seq[RegionRect]; horizontal: bool;
               tolerance: float): seq[seq[RegionRect]] =
  ## Partition `rects` by every straight cut along one axis. `horizontal`
  ## means cuts at x positions (a row). Returns one group per band, in order;
  ## a single group means no cut exists on this axis.
  var sorted = rects
  sorted.sort(proc (a, b: RegionRect): int =
    if horizontal: cmp(a.x, b.x) else: cmp(a.y, b.y))
  var groups: seq[seq[RegionRect]] = @[]
  var current: seq[RegionRect] = @[]
  var reach = -1e18
  for r in sorted:
    let start = if horizontal: r.x else: r.y
    let stop = if horizontal: r.x + r.w else: r.y + r.h
    if current.len > 0 and start >= reach - tolerance:
      groups.add current
      current = @[]
      reach = -1e18
    current.add r
    reach = max(reach, stop)
  if current.len > 0:
    groups.add current
  groups

proc build(rects: seq[RegionRect]; tolerance: float;
           problem: var string): ArrangementNode =
  if rects.len == 1:
    return ArrangementNode(axis: "", region: rects[0])
  let cols = cutsAlong(rects, horizontal = true, tolerance)
  if cols.len > 1:
    result = ArrangementNode(axis: "row")
    for g in cols:
      result.children.add build(g, tolerance, problem)
    return
  let rows = cutsAlong(rects, horizontal = false, tolerance)
  if rows.len > 1:
    result = ArrangementNode(axis: "column")
    for g in rows:
      result.children.add build(g, tolerance, problem)
    return
  var names: seq[string] = @[]
  for r in rects:
    names.add regionText(r)
  problem = "no straight cut separates " & names.join(", ")
  ArrangementNode(axis: "", region: rects[0])

proc flatten(n: ArrangementNode) =
  ## `row(row(a,b),c)` and `row(a,b,c)` are one arrangement; so are a
  ## container of one child and that child.
  if n.axis.len == 0:
    return
  var kids: seq[ArrangementNode] = @[]
  for c in n.children:
    flatten(c)
    if c.axis == n.axis:
      for g in c.children: kids.add g
    else:
      kids.add c
  n.children = kids

proc collect(n: ArrangementNode; into: var Arrangement) =
  if n.axis.len == 0:
    into.groups.add regionText(n.region)
    if n.region.active >= 0 and n.region.active < n.region.tabs.len:
      into.visible.incl n.region.tabs[n.region.active]
    return
  for c in n.children:
    collect(c, into)

proc visibleUnder(n: ArrangementNode): seq[string] =
  if n.axis.len == 0:
    if n.region.active >= 0 and n.region.active < n.region.tabs.len:
      return @[n.region.tabs[n.region.active]]
    return @[]
  for c in n.children:
    result.add visibleUnder(c)

proc beforeOf(n: ArrangementNode; into: var HashSet[string]) =
  ## At every container, each visible pane of an earlier child comes before
  ## each visible pane of a later one — the lowest-common-container rule.
  if n.axis.len == 0:
    return
  for i in 0 ..< n.children.len:
    for j in i + 1 ..< n.children.len:
      for a in visibleUnder(n.children[i]):
        for b in visibleUnder(n.children[j]):
          into.incl a & "<" & b
  for c in n.children:
    beforeOf(c, into)

proc finish(root: ArrangementNode; problem: string): Arrangement =
  flatten(root)
  result = Arrangement(before: initHashSet[string](),
                       visible: initHashSet[string](), problem: problem)
  result.canonical = canonicalOf(root)
  collect(root, result)
  beforeOf(root, result.before)
  result.groups.sort()

proc ofRegions*(rects: seq[RegionRect]; tolerance = 0.5): Arrangement =
  ## **A MEDIUM'S RELATION**, from the regions it drew. `tolerance` is how far
  ## a cut may run into a region's edge and still count as between two regions
  ## — a splitter's width, or a rounding.
  if rects.len == 0:
    return Arrangement(problem: "no regions",
                       before: initHashSet[string](),
                       visible: initHashSet[string]())
  var problem = ""
  let root = build(rects, tolerance, problem)
  finish(root, problem)

proc treeNode(n: LayoutNode): ArrangementNode =
  case n.kind
  of lnPane:
    ArrangementNode(axis: "", region: RegionRect(
      tabs: @[(if n.isContributed: n.contributedPane else: $n.pane)],
      active: 0))
  of lnStack:
    var tabs: seq[string] = @[]
    for c in n.children:
      tabs.add(if c.isContributed: c.contributedPane else: $c.pane)
    ArrangementNode(axis: "", region: RegionRect(tabs: tabs,
                                                  active: n.activeIndex))
  of lnRow, lnColumn:
    var node = ArrangementNode(axis: (if n.kind == lnRow: "row" else: "column"))
    for c in n.children:
      node.children.add treeNode(c)
    node

proc ofTree*(tree: LayoutNode): Arrangement =
  ## **THE MODEL'S RELATION** — the expected value a medium is compared with.
  if tree.isNil:
    return Arrangement(problem: "no tree", before: initHashSet[string](),
                       visible: initHashSet[string]())
  finish(treeNode(tree), "")

proc sameArrangement*(a, b: Arrangement): bool =
  a.problem.len == 0 and b.problem.len == 0 and
    a.canonical == b.canonical and a.before == b.before and
    a.groups == b.groups and a.visible == b.visible
