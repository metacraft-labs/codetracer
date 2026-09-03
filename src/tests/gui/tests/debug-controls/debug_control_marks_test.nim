## debug_control_marks_test.nim
##
## Headless checks on the debugger strip's mark table.
##
## WHAT THIS COVERS, AND WHAT IT DELIBERATELY DOES NOT.
## `ControlMarks` is the one place the strip's twelve marks are written down.
## This file checks the properties of that TABLE — that it is complete, that
## no two controls share a glyph, that every path is real, and that the two
## chevron pairs are exact 180° rotations of one another. All of that is
## decidable from the data and needs no browser.
##
## ON THE ONE CHECK HERE THAT IS ABOUT SHAPE.
## Everything else in this file is about the table's STRUCTURE — a count, a
## naming convention, an absence of colour literals — and holds for whatever
## the strip is drawn with. The pairing check is the exception: it names a
## property of particular artwork, so it has to say which artwork.
##
## It used to assert reflection about x=8, which was true of the codicon-
## derived set `93be377c` brought in and is not true of the set this product
## actually has. Correcting it rather than keeping it is the point: a test that
## names a shape can only ever record which shape was shipped, and if the shape
## is wrong the test is a second copy of the same mistake, not a check on it.
## So the assertion now states the pairing the restored marks DO have, and says
## plainly which pairs have no such pairing rather than inventing one for them.
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

proc rotated180(ps: seq[Pt]; centre: float): seq[Pt] =
  for p in ps:
    result.add (2.0 * centre - p.x, 2.0 * centre - p.y)

proc sameShape(a, b: seq[Pt]): bool =
  ## The two point lists describe the same outline.
  ##
  ## Compared as multisets, not in order: a rotation reverses the direction a
  ## closed subpath is traversed in, and `reverse_continue_dark.svg`'s dot
  ## really does run the opposite way round the circle from `continue_dark`'s.
  ## Direction is not part of what the mark looks like.
  if a.len != b.len: return false
  var remaining = b
  for p in a:
    var hit = -1
    for i, q in remaining:
      # 1e-3: the asset files truncate. `reverse_continue_dark.svg` writes
      # 12.3437 where the exact rotation of `continue_dark.svg` is 12.34375.
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

  test "the chevron pairs are exact 180° rotations about (8, 8)":
    # `continue`/`reverse-continue` and `next`/`reverse-next` are one drawing
    # each, turned upside down for the reverse direction: dot or rule moves
    # from the bottom of the box to the top, the V becomes a Λ. That is the
    # one systematic relationship in this set, so it is the one asserted.
    #
    # Both marks are two shapes — the dot-or-rule and the chevron — and both
    # have to rotate, in the order they are drawn in. A check on the chevron
    # alone would pass on a mark whose dot had migrated.
    for (fwd, rev) in [("continue", "reverse-continue"),
                       ("next", "reverse-next")]:
      let
        f = markFor(fwd)
        r = markFor(rev)
      check f.buttonId.len > 0
      check r.buttonId.len > 0
      check f.shapes.len == 2
      check r.shapes.len == 2
      for i in 0 ..< 2:
        let
        # `0 0 16 16`, so the centre of the box is (8, 8).
          got = rotated180(f.shapes[i].d.points.withoutCollinear, 8.0)
          want = r.shapes[i].d.points.withoutCollinear
        check sameShape(got, want)
        if not sameShape(got, want):
          echo "  '", fwd, "' shape ", i, " rotated is not '", rev, "'s"
          echo "    rotated: ", got
          echo "    actual:  ", want

  test "the four step marks have no such pairing, and that is the artwork":
    # Stated rather than left as an absence, because the obvious reading of
    # the test above is that the other pairs were forgotten. They were not.
    #
    # In this set `step-in` and `reverse-step-out` carry the SAME arrow, and
    # so do `step-out` and `reverse-step-in`; within each of those two groups
    # the marks are told apart only by whether the box beside the arrow is
    # outlined or filled, and by a one-unit difference in viewBox width. There
    # is no forward/reverse transform to assert because the pairs that share a
    # drawing are not the forward/reverse pairs.
    #
    # This is recorded, not endorsed: it is a fair part of why the strip is
    # going to a designer. What the check enforces is that the four remain
    # four DISTINCT marks — the failure that would actually mislead a user is
    # two controls rendering identically.
    var ds: seq[string]
    for a in ["step-in", "reverse-step-in", "step-out", "reverse-step-out"]:
      let m = markFor(a)
      check m.shapes.len == 2
      var key = ""
      for s in m.shapes:
        key.add s.d & "|"
      check key notin ds
      ds.add key
    # The arrows really are shared across the diagonal, which is the claim the
    # comment above makes. Asserting it means the comment cannot quietly go
    # stale against the artwork — and it is asserted as what the coordinates
    # actually say, not as an exact identity they do not have: the same number
    # of points, the same heights, and x within 0.6 of a 17-or-18 unit box.
    # The two are one drawing redrawn a shade wider, not a transform of one
    # another, so no transform is claimed.
    for (a, b) in [("step-in", "reverse-step-out"),
                   ("reverse-step-in", "step-out")]:
      let
        pa = markFor(a).shapes[0].d.points
        pb = markFor(b).shapes[0].d.points
      check pa.len == pb.len
      if pa.len == pb.len:
        var maxDx, maxDy = 0.0
        for i in 0 ..< pa.len:
          maxDx = max(maxDx, abs(pa[i].x - pb[i].x))
          maxDy = max(maxDy, abs(pa[i].y - pb[i].y))
        check maxDy < 0.01     # the same heights, to the file's rounding
        check maxDx < 0.6      # and within a unit across
        if maxDy >= 0.01 or maxDx >= 0.6:
          echo "  '", a, "' and '", b, "' differ by dx=", maxDx,
               " dy=", maxDy, " — they are no longer the same drawing"

  test "run-to-entry is a restart mark, not a transport control":
    # It sends DAP `restart`, and every product surveyed draws a restart as a
    # circular arrow. It used to be a play triangle beside a stack of lines,
    # which is what a reader identified as a media control on the sibling
    # product. `debug-restart` carries no triangle: one subpath, all curves,
    # and the only straight runs are the arrowhead bracket.
    let m = markFor("run-to-entry")
    check m.buttonId == "run-to-entry-image"
    check m.shapes.len == 1
    let d = m.shapes[0].d
    check d.count('C') > 20          # a sweep built from cubics
    check d.count('Z') == 1          # one closed subpath, not a triangle
                                     # sitting beside a stack of rules
    # The old mark was five parallel `M x yLx y` rules plus a triangle; it had
    # no curves at all.
    check d.count('C') > d.count('L')

  test "markFor answers nothing for a command the strip does not have":
    check markFor("no-such-command").buttonId.len == 0
    check markFor("run-tests").buttonId.len == 0   # deliberately not a mark
