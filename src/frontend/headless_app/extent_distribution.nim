## headless_app/extent_distribution.nim — PLAT-20. **One largest-remainder
## distribution, shared by every projection of a `LayoutNode`.**
##
## ## Why this is its own module rather than a second copy
##
## `tui/app/layout/project.nim` has divided a parent's integer extent among its
## children in the weights' proportions since CTUI-3, and PLAT-20's GPUI dock
## projection has to do exactly the same arithmetic — `PanelInfo::Stack` in
## gpui-kit's persisted schema carries a `sizes: Vec<Pixels>`, so a projection
## that declines to compute one cannot be written at all.
##
## Copying the routine would be
## `codetracer-specs/Testing/Verification-Harness-Traps.md` §14 by the letter:
## *"one predicate, one function, rule and control both calling it"*. It would
## also quietly weaken PLAT-20's own cross-projection test, whose whole subject
## is that the terminal and the GPUI arrangements agree — two independently
## drifting distributions would make that agreement a coincidence of two
## implementations rather than a property of one.
##
## It lives under `headless_app/` and NOT under either front-end because either
## placement would make one front-end import the other's tree:
## `tui/app/layout/project.nim` imports `isonim_tui`, so a GPUI module that
## reached into it would drag a terminal renderer into a lane that does not
## link one — which is the same argument PLAT-4's status block makes for
## keeping the floating-panel assertion out of the `vm-unit` lane.
##
## ## What it is NOT
##
## It is not a layout model and it decides nothing about layout. It is integer
## arithmetic over a total and a list of shares, and the three properties below
## are the whole of its contract.

import std/[algorithm, math]

proc distributeExtent*(total: int; shares: openArray[float]): seq[int] =
  ## Split `total` units among `shares.len` siblings in the given proportions.
  ##
  ## THREE PROPERTIES, all of them relied on by both projections and all of
  ## them asserted directly in
  ## `tui/app/tests/test_layout_node_projection.nim` and in
  ## `gpui/tests/test_gpui_dock_projection.nim`:
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
  ## a refusal rather than handing back a zero-width pane.
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
  # Lift every zero to one by taking a unit from the largest sibling. Runs at
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
