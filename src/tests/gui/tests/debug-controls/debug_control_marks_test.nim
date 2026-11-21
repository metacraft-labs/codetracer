## debug_control_marks_test.nim
##
## Headless checks on the debugger strip's mark table.
##
## WHAT THIS COVERS, AND WHAT IT DELIBERATELY DOES NOT.
## `ControlMarks` is the one place the strip's twelve marks are written down.
## This file checks the properties of that TABLE — that it is complete, that
## no two controls share a glyph, that every path is real, and that the
## transport marks keep their grammar: every reverse mark is its forward mark
## mirrored, step in points at its dot and step out away from it. All of that
## is decidable from the data and needs no browser.
##
## ON THE CHECKS HERE THAT ARE ABOUT SHAPE.
## Everything else in this file is about the table's STRUCTURE — a count, a
## naming convention, an absence of colour literals — and holds for whatever
## the strip is drawn with. The grammar checks are the exception: they name
## properties of the transport marks' artwork, which is drawn to that grammar
## so that a reverse control cannot be mistaken for its forward twin.
##
## It cannot check the thing that actually broke: whether a mark is PAINTED.
## A table can be perfect while the strip renders nothing, which is close to
## what shipped — the white theme named twelve asset variables it never
## defined, so the built CSS carried unparseable declarations and the bar was
## blank. That claim is only decidable in a browser, and it is asserted in
## `toolbar-marks-contrast.spec.ts`, which measures each mark's computed
## colour against its computed background in both themes. The two are
## complements: this one is fast and runs everywhere, that one is the only
## one that can see.
##
## Compile and run:
##   nim c --path:src/frontend/viewmodel --nimcache:/tmp/ct-nim-cache/marks \
##     -o:/tmp/ct-nim-cache/marks/t \
##     src/tests/gui/tests/debug-controls/debug_control_marks_test.nim
##   /tmp/ct-nim-cache/marks/t

import std/[unittest, strutils, sets, tables, math]
import views/debug_control_marks

## Every command the strip is expected to carry a mark for, written out here
## rather than derived from `ControlMarks`. Deriving it would make the check
## a tautology: any table would satisfy a list built from itself.
const ExpectedActions = [
  "history-back", "history-forward",
  "reverse-next", "next",
  "reverse-step-in", "step-in",
  "reverse-step-out", "step-out",
  "reverse-continue", "continue",
  "run-to-entry", "reset-operation",
]

type Pt = tuple[x, y: float]

proc points(d: string): seq[Pt] =
  ## Every point a path visits, control points included.
  ##
  ## Absolute commands only, which is all the strip's paths use. `H` and `V`
  ## carry one coordinate and inherit the other from the current point, so the
  ## current point is tracked rather than the coordinates being read in pairs.
  var
    pts: seq[Pt]
    cmd = ' '
    cur: Pt = (0.0, 0.0)
    nums: seq[float]
    i = 0

  template flush() =
    ## Turn the numbers gathered since the last command letter into points.
    case cmd
    of 'M', 'L', 'C', 'S', 'Q', 'T':
      var k = 0
      while k + 1 < nums.len:
        cur = (nums[k], nums[k + 1])
        pts.add cur
        k += 2
    of 'H':
      for v in nums:
        cur = (v, cur.y)
        pts.add cur
    of 'V':
      for v in nums:
        cur = (cur.x, v)
        pts.add cur
    of 'A':
      # `rx ry rot large sweep x y` — only the endpoint is a point. The radii
      # are lengths and the flags are booleans; rotating either would be
      # nonsense, so they are dropped rather than mapped.
      var k = 0
      while k + 6 < nums.len:
        cur = (nums[k + 5], nums[k + 6])
        pts.add cur
        k += 7
    else: discard
    nums.setLen 0

  while i < d.len:
    let c = d[i]
    if c.isAlphaAscii:
      flush()
      cmd = c
      inc i
    elif c in {' ', ','}:
      inc i
    else:
      var j = i
      if d[j] in {'-', '+'}: inc j
      while j < d.len and (d[j].isDigit or d[j] == '.'):
        inc j
      # An exponent, which `reverse_continue_dark.svg`'s dot has: Figma wrote
      # its zeroes as `-7.8281e-08`, and stopping the scan at the `e` would
      # read the mantissa as a coordinate and the exponent as another command.
      if j < d.len and d[j] in {'e', 'E'}:
        inc j
        if j < d.len and d[j] in {'-', '+'}: inc j
        while j < d.len and d[j].isDigit: inc j
      nums.add parseFloat(d[i ..< j])
      i = j
  flush()
  pts

proc withoutCollinear(ps: seq[Pt]): seq[Pt] =
  ## Drop points that lie on the straight line between their neighbours.
  ##
  ## `next_dark.svg` and `reverse_next_dark.svg` both plant a redundant point
  ## in the middle of one arm of their chevron — but not on the SAME arm, so
  ## the two files describe one shape with two different point lists. Dropping
  ## points that add nothing to the outline is what lets the check compare the
  ## shapes rather than the transcriptions.
  for i, p in ps:
    if i == 0 or i == ps.high:
      result.add p
      continue
    let
      a = ps[i - 1]
      b = ps[i + 1]
      base = hypot(b.x - a.x, b.y - a.y)
      cross = (p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x)
    # `cross` is twice the triangle's area, so it grows with the neighbours'
    # separation; dividing by that separation gives the point's perpendicular
    # distance from the line, which is the thing a threshold can be stated in.
    # 0.01 of a 16-unit box — the files round their coordinates to five
    # figures, which leaves `next_dark.svg`'s midpoint 3e-5 units off the line
    # it is exactly on.
    if base < 1e-9 or abs(cross) / base > 0.01:
      result.add p

proc mirrored(ps: seq[Pt]; centre: float): seq[Pt] =
  ## Reflected about the vertical line x = `centre`.
  for p in ps:
    result.add (2.0 * centre - p.x, p.y)

proc sameShape(a, b: seq[Pt]): bool =
  ## The two point lists describe the same outline.
  ##
  ## Compared as multisets, not in order: a mirror reverses the direction a
  ## closed subpath is traversed in (a mirrored dot runs the other way round
  ## the circle). Direction is not part of what the mark looks like.
  if a.len != b.len: return false
  var remaining = b
  for p in a:
    var hit = -1
    for i, q in remaining:
      # 1e-3: the coordinates are written to four decimals.
      if abs(p.x - q.x) < 1e-3 and abs(p.y - q.y) < 1e-3:
        hit = i
        break
    if hit < 0: return false
    remaining.delete hit
  true

suite "Debugger control marks — the table":

  test "the strip carries every command's mark, and only those":
    check ControlMarks.len == ControlMarkCount
    var seen = initHashSet[string]()
    for m in ControlMarks:
      seen.incl m.action
    for a in ExpectedActions:
      check a in seen
    check seen.len == ExpectedActions.len

  test "the count is stated independently, so a dropped mark is visible":
    # The trap: `ControlMarks.len == ControlMarks.len` passes for every
    # table, including an empty one, so a count compared against its own
    # collection cannot notice a control being dropped. `ControlMarkCount` is
    # a literal for that reason. Here is a table whose count DIFFERS, proving
    # the comparison bites rather than being satisfied by coincidence.
    let short = ControlMarks[0 ..< ControlMarks.len - 1]
    check short.len != ControlMarkCount
    check short.len == ControlMarkCount - 1
    # And one that is longer, so the check is not merely "not fewer".
    let long = ControlMarks & @[ControlMarks[0]]
    check long.len != ControlMarkCount

  test "no two controls wear the same glyph":
    # Midas ships its reverse-finish with the forward step-out icon verbatim
    # — two controls, one mark. That is the failure this forbids.
    var byShape = initTable[string, string]()
    for m in ControlMarks:
      var key = ""
      for s in m.shapes:
        key.add s.d & "|"
      check not byShape.hasKey(key)
      if byShape.hasKey(key):
        echo "  '", m.action, "' shares a glyph with '", byShape[key], "'"
      byShape[key] = m.action

  test "every button id is distinct and names its action":
    var ids = initHashSet[string]()
    for m in ControlMarks:
      check m.buttonId.len > 0
      check m.buttonId notin ids
      ids.incl m.buttonId
      # The view finds buttons by this id; the `{action}-image` convention is
      # what keeps the table and the toolbar in step.
      check m.buttonId == m.action & "-image"

  test "every mark has geometry, and none of it names a colour":
    for m in ControlMarks:
      check m.shapes.len > 0
      check m.viewBox.len > 0
      for s in m.shapes:
        check s.d.len > 0
        check s.d[0] == 'M'
        if s.stroked:
          check s.strokeWidth.len > 0
      # The whole point of the module: a mark that carried a colour could not
      # follow a theme, which is how the strip came to be invisible on one.
      let markup = m.svgMarkup()
      check "currentColor" in markup
      check '#' notin markup
      check "rgb" notin markup

  test "every reverse mark is its forward mark mirrored about x = 8":
    # The grammar's second rule: time runs left to right, so the ONLY
    # difference between a forward control and its reverse twin is the
    # direction the mark points. Every shape of the pair has to mirror, in the
    # order they are drawn in — a check on the arrow alone would pass on a mark
    # whose dot had stayed where it was.
    for (fwd, rev) in [("next", "reverse-next"), ("step-in", "reverse-step-in"),
                       ("step-out", "reverse-step-out"),
                       ("continue", "reverse-continue")]:
      let
        f = markFor(fwd)
        r = markFor(rev)
      check f.buttonId.len > 0
      check r.buttonId.len > 0
      check f.viewBox == "0 0 16 16"
      check r.viewBox == f.viewBox
      check f.shapes.len == r.shapes.len
      for i in 0 ..< min(f.shapes.len, r.shapes.len):
        check f.shapes[i].stroked == r.shapes[i].stroked
        let
          got = mirrored(f.shapes[i].d.points.withoutCollinear, 8.0)
          want = r.shapes[i].d.points.withoutCollinear
        check sameShape(got, want)
        if not sameShape(got, want):
          echo "  '", fwd, "' shape ", i, " mirrored is not '", rev, "'s"
          echo "    mirrored: ", got
          echo "    actual:   ", want

  test "a pair is not symmetric itself, so the mirror tells it apart":
    # A mark that is its own mirror image would satisfy the test above while
    # drawing the forward and reverse controls identically — the defect the
    # grammar exists to remove.
    for fwd in ["next", "step-in", "step-out", "continue"]:
      let f = markFor(fwd)
      var allSame = true
      for sh in f.shapes:
        let ps = sh.d.points.withoutCollinear
        if not sameShape(mirrored(ps, 8.0), ps): allSame = false
      check not allSame

  test "the step marks say in or out by where the arrow points":
    # The grammar's first rule: the dot is where execution is. Step in points
    # DOWN at its dot, step out starts at its dot and points UP. The head is
    # the second shape and the dot the third; the head's middle point is its
    # tip.
    proc tipAndDot(action: string): (Pt, Pt, Pt) =
      let m = markFor(action)
      let head = m.shapes[1].d.points
      let dot = m.shapes[2].d.points
      var lo, hi = dot[0]
      for p in dot:
        lo = (min(lo.x, p.x), min(lo.y, p.y))
        hi = (max(hi.x, p.x), max(hi.y, p.y))
      (head[1], head[0], ((lo.x + hi.x) / 2, (lo.y + hi.y) / 2))
    for a in ["step-in", "reverse-step-in"]:
      let (tip, wing, dot) = tipAndDot(a)
      check tip.y > wing.y                 # the head points down
      check abs(tip.x - dot.x) < 1e-6      # straight at the dot
      check tip.y < dot.y
    for a in ["step-out", "reverse-step-out"]:
      let (tip, wing, dot) = tipAndDot(a)
      check tip.y < wing.y                 # the head points up
      check tip.y < dot.y - 6.0            # far from the dot it leaves
    for a in ["next", "reverse-next", "step-in", "reverse-step-in",
              "step-out", "reverse-step-out"]:
      let m = markFor(a)
      check m.shapes.len == 3
      check m.shapes[0].stroked and m.shapes[1].stroked
      check not m.shapes[2].stroked        # the dot is solid

  test "forward marks point right, reverse marks left":
    # Read off the one horizontal cue each pair carries: next's head, the
    # step marks' horizontal leg running from its free end, continue's
    # triangle tip.
    proc tipX(action: string): float =
      let m = markFor(action)
      case action
      of "next", "reverse-next": m.shapes[1].d.points[1].x
      of "continue", "reverse-continue": m.shapes[1].d.points[1].x
      else: m.shapes[0].d.points[1].x
    proc baseX(action: string): float =
      let m = markFor(action)
      case action
      of "continue", "reverse-continue": m.shapes[0].d.points[0].x
      of "next", "reverse-next": m.shapes[0].d.points[0].x
      else: m.shapes[0].d.points[0].x
    for a in ["next", "step-in", "step-out", "continue"]:
      check tipX(a) > baseX(a)
      check tipX("reverse-" & a) < baseX("reverse-" & a)

  test "run-to-entry is skip-to-start: two triangles pointing at a bar":
    # Distinct from reverse-continue, which is ONE triangle pointing away from
    # its bar: the TUI's text mark for this control is `⏮`, and so is this.
    let m = markFor("run-to-entry")
    check m.buttonId == "run-to-entry-image"
    check m.shapes.len == 3
    check m.shapes[0].stroked
    let bar = m.shapes[0].d.points
    check bar.len == 2
    check abs(bar[0].x - bar[1].x) < 1e-6           # vertical
    for i in 1 .. 2:
      let tri = m.shapes[i]
      check not tri.stroked
      let tp = tri.d.points
      check tp.len == 3
      check tp[1].x < tp[0].x and tp[1].x < tp[2].x   # tip to the LEFT
      check tp[1].x > bar[0].x                         # right of the bar
    check markFor("reverse-continue").shapes.len == 2

  test "markFor answers nothing for a command the strip does not have":
    check markFor("no-such-command").buttonId.len == 0
    check markFor("run-tests").buttonId.len == 0   # deliberately not a mark
