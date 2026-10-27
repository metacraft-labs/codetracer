## test_plat70a_gpui_window.nim — PLAT-70 Part A (Horizontal-Overflow.md §4),
## **the GPUI window's text panes scrolled sideways, read from its pixels**.
##
## The record `src/tests/visual/plat70a-gpui-window.json` is MEASURED off a
## real window on a headless sway, on the `wide_lines` recording, driven by a
## real pointer device (isonim-gpui's `build/virtual-pointer`, whose `hwheel`
## turns the horizontal axis) and real keys (`wtype` holding Shift):
## `just plat70a-gpui-window`, then `just plat70a-gpui-window-record` —
## `ci/test/plat70a_gpui_window.py` says what every frame is. This suite
## asserts over the committed measurement, the arrangement PLAT-40..48 use.
##
## What a step DID is read from the frames: where the bar's thumb lies on the
## bar's own pixel row. The window's own trace line (`editor-hscroll
## leftCols=…`) is carried under `reportedByWindow` and asserted only BESIDE
## the pixel evidence for the same step, never instead of it.
##
## No mocks: a real window, a real compositor, a real pointer, the real
## `wide_lines` recording replayed by a real replay-server.

import std/[json, os, unittest]

import codetracer_embed
from gpui/app/leaves import EditorScrollbarMinThumbPx
from gpui/terminal_output_leaf import TerminalTrackPx

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Record = "src/tests/visual/plat70a-gpui-window.json"
  ExpectedAssertions = 36

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

proc arr(n: JsonNode): seq[int] =
  for v in n.getElems: result.add v.getInt

suite "PLAT-70 Part A: the GPUI window's horizontal scroll, read from its pixels":

  let rec = parseJson(readFile(repo / Record))
  let ed = arr(rec["editorBody"])
  let term = arr(rec["terminalBody"])
  let th = rec["thumbs"]
  let said = rec["reportedByWindow"]

  proc thumb(step: string): tuple[y, first, last: int] =
    let t = th[step]
    if t.kind == JNull: return (-1, -1, -1)
    (t["y"].getInt, t["first"].getInt, t["last"].getInt)

  test "every frame of the capture settled":
    var n = 0
    for k, v in rec["steps"]:
      checkpoint(k)
      ck v.getBool
      inc n
    ck n == 6

  test "the editor's bar: under its rows, inside the pane, thumb at the start":
    let b = thumb("base")
    # Drawn (HO-1: the wide line overflows), on the pane's last pixel rows …
    ck b.y >= ed[1] + ed[3] - 14 and b.y < ed[1] + ed[3]
    # … inside the pane's width, and at rest the view starts at column 0: the
    # thumb sits at the track's left end (the gutter's width in).
    ck b.first > ed[0] and b.last < ed[0] + ed[2]
    ck b.first - ed[0] < 40
    # The thumb is the view's share of the content: much narrower than the
    # pane, never thinner than the minimum.
    ck b.last - b.first + 1 >= EditorScrollbarMinThumbPx - 2
    ck b.last - b.first < ed[2] div 3

  test "the real horizontal wheel over the editor moves the view right":
    let b = thumb("base")
    let w = thumb("hwheel")
    ck w.y == b.y
    ck w.first > b.first                     # the pixels moved right …
    ck said["hwheel"]["left"].getInt > 0     # … and the window says so
    ck said["hwheel"]["left"].getInt mod WheelColumns == 0

  test "Shift + the vertical wheel scrolls sideways too (§4.3)":
    let w = thumb("hwheel")
    let s = thumb("shift-wheel")
    ck s.y == w.y
    ck s.first > w.first
    # The same distance as one horizontal notch: the wheel read as `dx`.
    # Measured at the thumb's RIGHT end: at rest the caret's mark (column 0,
    # §4.2) is drawn over the thumb's first pixels.
    ck abs((s.last - w.last) - (w.last - thumb("base").last)) <= 2
    ck said["shift-wheel"]["left"].getInt == 2 * said["hwheel"]["left"].getInt

  test "a press on the track centres the column under it (§4.2)":
    let s = thumb("shift-wheel")
    let t = thumb("track")
    ck t.y == s.y
    # Pressed at 90% of the pane's width: the thumb jumps there, centred on
    # the pointer, and stays inside the track.
    let pressX = ed[0] + int(float(ed[2]) * 0.9)
    ck t.first > s.last
    ck abs((t.first + t.last) div 2 - pressX) <= 3
    ck t.last < ed[0] + ed[2]
    ck said["track"]["line"].getStr.len > 0
    ck said["track"]["left"].getInt > said["shift-wheel"]["left"].getInt
    ck said["track"]["left"].getInt <= said["track"]["max"].getInt + 1

  test "Terminal Output: its own bar, beside the vertical track, not under it":
    let t = thumb("terminal")
    # Drawn on the pane's last rows …
    ck t.y >= term[1] + term[3] - 50 and t.y < term[1] + term[3]
    # … starting at the text's left edge at rest …
    ck t.first > term[0] and t.first - term[0] < 30
    # … and ending short of the vertical track's column: the corner is
    # neither's (HO-7).
    ck t.last < term[0] + term[2] - TerminalTrackPx
    ck t.last - t.first < term[2]

  test "the real horizontal wheel over Terminal Output moves its view":
    let t = thumb("terminal")
    let w = thumb("term-hwheel")
    ck w.y == t.y
    ck w.first > t.first
    ck w.last - w.first == t.last - t.first   # the view's width is unchanged
    ck said["term-hwheel"]["left"].getInt > 0
    ck said["term-hwheel"]["line"].getStr.len > 0

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
