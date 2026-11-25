## code_digits_test.nim — the GPUI binding reads a code-face number's digits
## by their outlines, not by the OCR engine's word alone.
##
## The defect (codetracer-pm issues/2026-11-25-the-gpui-scenario-binding-
## reads-a-variables-lone-digit-6-as-8.md): in `mul(left, right)` of the
## `calc` recording the GPUI window's Variables pane draws `left:6 Int`, and
## the binding reported `value="8"` — Tesseract reads the code face's lone 6
## as an 8 at the pane's size. The governing rule is codetracer-pm
## spec/Testing/GPUI-Binding-Code-Face-Digits.md.
##
## The fixture is a real capture of the window (`fixtures/calc-mul-left-6.png`,
## the GPUI lane's tour run stopped in `mul(left=6, right=7)`, step 48 of
## `tour/calc-debugging-session.yaml`; the pane shows `left:6 Int`), read through the
## binding's own `readSurface` and the real OCR engine — nothing is mocked:
## the surface under test IS pixels and OCR, and the frame is the window's.
##
## Run: ci/test/scenarios.sh gui-binding-test

import std/[json, os, strutils, tables]
import demo_video_script_guiassert
import ./ct_gui_binding
import ./code_digits

const fixture = currentSourcePath().parentDir / "fixtures" / "calc-mul-left-6.png"

var failures = 0

proc check(cond: bool; what: string) =
  ## A failed comparison counts; the test exits non-zero at the end.
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc variable(t: Tree; name: string): SurfaceNode =
  for n in t.kids(t.root):
    if n.role == "variables":
      for v in t.kids(n):
        if v.props{"name"}.getStr == name: return v
  nil

if not fileExists(fixture):
  # a missing fixture is a failure, never a skip
  echo "FAIL: the fixture frame is missing at ", fixture
  quit 1

let ctx = newOfflineContext(getTempDir() / ("code-digits-test-" & $getCurrentProcessId()))
let frame = frameOf(fixture)

echo "the Variables pane's numbers, through readSurface and the OCR engine"
let t = readSurface(ctx, frame)
for (name, want) in [("left", "6")]:
  let v = t.variable(name)
  check(v != nil, "a variable named " & name & " is read")
  if v != nil:
    check(not v.unreadable.hasKey("value"),
          name & "'s value is readable (" & v.unreadable.getOrDefault("value") & ")")
    check(v.props{"value"}.getStr == want,
          name & "'s value is " & want & " (read: " & v.props{"value"}.getStr & ")")

echo "every digit glyph of the code face reads as itself, a letter as none"
# Each entry: a glyph's box in the fixture (x0, x1, y0, y1, ground x, ground
# y) and the digit drawn there (-1: not a digit). Measured on the fixture.
include ./fixtures/calc_mul_left_6_glyphs
for g in Glyphs:
  let (x0, x1, y0, y1, gx, gy, want) = g
  let i = (gy * frame.image.width + gx) * 3
  let ground = (ord(frame.image.pixels[i]), ord(frame.image.pixels[i + 1]),
                ord(frame.image.pixels[i + 2]))
  # the binding's own reduction of a glyph to coverage
  let cov = frame.glyphCoverage(x0, x1, y0, y1, ground)
  let r = readDigit(cov, 16.0)
  check(r.digit == want, "glyph @" & $x0 & "," & $y0 & " reads " & $r.digit & ", drawn " & $want &
        " (score " & r.score.formatFloat(ffDecimal, 3) & ", next " &
        r.runnerUp.formatFloat(ffDecimal, 3) & ", contrast " & r.contrast.formatFloat(ffDecimal, 3) & ")")

echo "the colon before a value is told from a point or a sign by its two dots"
# (x0, x1, y0, y1): a run of ink as the binding cuts it, and its row band
for (x0, x1, y0, y1, want) in [(777, 777, 456, 481, 2),    # v ':' of `left:6`
                               (1008, 1012, 627, 652, 1),  # e2 '-'
                               (1018, 1022, 682, 707, 1)]: # e4 '/'
  let got = inkBands(frame, x0, x1, y0, y1)
  check(got == want, "run @" & $x0 & "," & $y0 & " holds " & $got & " band(s) of ink, drawn " & $want)

removeDir(ctx.workDir)
if failures > 0:
  echo failures, " check(s) failed"
  quit 1
echo "all checks passed"
