## test_m71_gpui_window.nim — M71 (codetracer#838) in the GPUI window, **the
## State, Files and VCS panes' scrollbars read from its pixels**.
##
## The record `src/tests/visual/m71-gpui-window.json` is MEASURED off a real
## window on a headless sway, on the `multi_root` recording one step in, in a
## layout where all three panes hold fewer rows than they list, with the VCS
## pane over a git repository of sixty-odd files, driven by a real pointer
## device (isonim-gpui's `build/virtual-pointer`, whose `wheel` turns the
## vertical axis by discrete notches): `just m71-gpui-window`, then
## `just m71-gpui-window-record` — `ci/test/m71_gpui_window.py` says what
## every frame is. This suite asserts over the committed measurement, the
## arrangement PLAT-40..70 use.
##
## The specs: Scrollbar-Scrubbers.md §2 (a pane whose whole content is in
## hand "keeps an ordinary scrollbar", §3's press "applies to it as well"),
## §4 (the GPUI track along the pane's right edge), CodeTracer-TUI.md §4.4
## (the wheel scrolls the pane beneath the pointer). The window-plan suite
## (`test_m71_gpui_plan.nim`) shows the window's ELEMENTS; this one shows they
## are DRAWN where they belong and move.
##
## What a step DID is read from the frames: in each pane's right-edge strip,
## the thumb's column and its first and last pixel rows. The window's own
## trace line (`vcs top=…`) is carried under `reportedByWindow` and asserted
## only BESIDE the pixel evidence for the same step, never instead of it.
##
## No mocks: a real window, a real compositor, a real pointer, the real
## `multi_root` recording replayed by a real replay-server, a real git
## repository.

import std/[json, os, unittest]

import gpui/window_geometry
from gpui/list_scrubber import listTrackRect
from gpui/app/leaves import StateRowsTopPx, StateScrollbarPx

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Record = "src/tests/visual/m71-gpui-window.json"
  ExpectedAssertions = 32
  EdgeSlackPx = 2
    ## A thumb's rounded ends (`rounded: 3px`) blend into the ground, so its
    ## first and last pixel rows may read a pixel or two inside its box.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

type Thumb = tuple[found: bool, x, first, last: int]

proc arr(n: JsonNode): seq[int] =
  for v in n.getElems: result.add v.getInt

suite "M71: the GPUI window's State, Files and VCS scrollbars, read from its pixels":

  let rec = parseJson(readFile(repo / Record))
  let th = rec["thumbs"]
  let said = rec["reportedByWindow"]

  proc body(pane: string): PxRect =
    let b = arr(rec["bodies"][pane])
    PxRect(x: b[0], y: b[1], w: b[2], h: b[3])

  proc thumb(step, pane: string): Thumb =
    let t = th[step][pane]
    if t.kind == JNull: return (false, -1, -1, -1)
    (true, t["x"].getInt, t["first"].getInt, t["last"].getInt)

  proc stateTrack(): PxRect =
    ## The State box's vertical bar (`leaves.stateScrollbars`): its right
    ## `StateScrollbarPx`, from `StateRowsTopPx` below the body's top.
    let b = body("state")
    PxRect(x: b.x + b.w - StateScrollbarPx, y: b.y + StateRowsTopPx,
           w: StateScrollbarPx, h: b.h - StateRowsTopPx)

  proc trackOf(pane: string): PxRect =
    if pane == "state": stateTrack() else: listTrackRect(body(pane), pane)

  proc inTrack(t: Thumb; pane: string): bool =
    ## The thumb lies in its pane's track: its column inside the track's,
    ## its rows inside the track's.
    let r = trackOf(pane)
    checkpoint(pane & " thumb " & $t & " track " & $r)
    t.found and t.x >= r.x and t.x < r.x + r.w and
      t.first >= r.y - EdgeSlackPx and t.last < r.y + r.h + EdgeSlackPx

  test "every frame of the capture settled":
    var n = 0
    for k, v in rec["steps"]:
      checkpoint(k)
      ck v.getBool
      inc n
    ck n == 4

  test "at rest each pane draws its scrollbar in its track at its right edge, the thumb at the top":
    for pane in ["vcs", "fileTree", "state"]:
      let t = thumb("base", pane)
      let r = trackOf(pane)
      # Drawn in the track the window places at the pane's right edge
      # (Scrollbar-Scrubbers.md §4) …
      ck t.inTrack(pane)
      # … the view at its first row puts the thumb at the track's top …
      ck t.first - r.y <= EdgeSlackPx
      # … and the rows overflow, so it is shorter than the track.
      ck t.last - t.first + 1 < r.h - EdgeSlackPx

  test "the real wheel over the VCS pane moves its thumb down, and only its":
    let b = thumb("base", "vcs")
    let w = thumb("vcs-wheel", "vcs")
    ck w.inTrack("vcs")
    ck w.x == b.x
    ck w.first > b.first                       # the pixels moved down …
    ck abs((w.last - w.first) - (b.last - b.first)) <= EdgeSlackPx
    ck said["vcs-wheel"]["top"].getInt > 0     # … and the window says so
    # The Files pane, not under the pointer, did not move.
    ck thumb("vcs-wheel", "fileTree") == thumb("base", "fileTree")

  test "the real wheel over the Files pane moves its thumb down, and only its":
    let b = thumb("vcs-wheel", "fileTree")
    let w = thumb("files-wheel", "fileTree")
    ck w.inTrack("fileTree")
    ck w.x == b.x
    ck w.first > b.first
    ck abs((w.last - w.first) - (b.last - b.first)) <= EdgeSlackPx
    ck said["files-wheel"]["top"].getInt > 0
    ck thumb("files-wheel", "vcs") == thumb("vcs-wheel", "vcs")

  test "a press on the State bar near its foot moves its thumb there (§3)":
    let b = thumb("files-wheel", "state")
    let p = thumb("state-press", "state")
    let r = stateTrack()
    let pressY = r.y + int(float(r.h) * 0.9)
    ck p.inTrack("state")
    ck p.x == b.x
    ck p.first > b.first
    # §3.2: the press centres the rows at its fraction — the thumb lies
    # over the press, unless it has reached the track's end first.
    ck (p.first <= pressY + EdgeSlackPx and p.last >= pressY - EdgeSlackPx) or
       p.last >= r.y + r.h - 1 - EdgeSlackPx
    ck said["state-press"]["top"].getInt > 0
    # A press on the State bar moves no other pane's view.
    ck thumb("state-press", "vcs") == thumb("files-wheel", "vcs")

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
