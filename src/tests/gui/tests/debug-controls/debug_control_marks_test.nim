## debug_control_marks_test.nim
##
## Headless checks on the debugger strip's mark table.
##
## WHAT THIS COVERS, AND WHAT IT DELIBERATELY DOES NOT.
## `ControlMarks` is the one place the strip's twelve marks are written down.
## This file checks the properties of that TABLE — that it is complete, that
## no two controls share a glyph, that every path is real, and that the two
## drawn pairs are exact reflections of one another. All of that is decidable
## from the data and needs no browser.
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

import std/[unittest, strutils, sets, tables]
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

proc reflectAboutX8(d: string): string =
  ## Mirror a path's x coordinates about x=8.
  ##
  ## Only sound for the four drawn step arrows, which are `M`/`L` polylines
  ## in absolute coordinates with no curves — that is why they are the only
  ## paths this is applied to.
  var
    outParts: seq[string]
    i = 0
    isX = true
  while i < d.len:
    if d[i] in {'M', 'L'}:
      outParts.add $d[i]
      isX = true
      inc i
    elif d[i] in {' ', ','}:
      inc i
    else:
      var j = i
      while j < d.len and (d[j].isDigit or d[j] in {'.', '-'}):
        inc j
      let v = parseFloat(d[i ..< j])
      let w = if isX: 16.0 - v else: v
      outParts.add(formatFloat(w, ffDecimal, 4).strip(trailing = true,
                                                      chars = {'0'})
                     .strip(trailing = true, chars = {'.'}))
      isX = not isX
      i = j
  outParts.join(" ")

proc normalised(d: string): string =
  d.replace(" ", "").replace(",", "")

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

  test "a reverse mark is its forward partner reflected about x=8":
    # microsoft/vscode#85111's rule for the family. It is checkable only for
    # the four drawn arrows; the codicon pairs are Microsoft's own artwork
    # and are not required to be exact mirrors.
    for (fwd, rev) in [("step-in", "reverse-step-in"),
                       ("step-out", "reverse-step-out")]:
      let f = markFor(fwd)
      let r = markFor(rev)
      check f.buttonId.len > 0
      check r.buttonId.len > 0
      # shape[0] is the shared dot; shape[1] is the arrow that carries the
      # handedness.
      check f.shapes.len == 2
      check r.shapes.len == 2
      check f.shapes[0].d == r.shapes[0].d   # same badge
      check normalised(reflectAboutX8(f.shapes[1].d)) ==
            normalised(r.shapes[1].d)

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
