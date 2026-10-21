## test_plat70b_gpui_window.nim — PLAT-70 Part B (Horizontal-Overflow.md §5),
## **the GPUI window's table panes, read from its pixels**.
##
## The record `src/tests/visual/plat70b-gpui-window.json` is MEASURED off a
## real window on a headless sway, on the `wide_lines` recording, driven by a
## real pointer device (isonim-gpui's `build/virtual-pointer`) and real keys
## (`wtype`): `just plat70b-gpui-window`, then `just
## plat70b-gpui-window-record` — `ci/test/plat70b_gpui_window.py` says what
## every frame is. This suite asserts over the committed measurement, the
## arrangement PLAT-40..48 and PLAT-70 Part A use.
##
## What a step DID is read from the frames: the box of pixels that changed
## between a step's frame and the one before it. The window's own trace lines
## (`cell hover`, `cell tooltip`, `detail open`, `event log column # N
## cells`) are carried under `reportedByWindow` and asserted only BESIDE the
## pixel evidence for the same step, never instead of it.
##
## No mocks: a real window, a real compositor, a real pointer, the real
## `wide_lines` recording replayed by a real replay-server.

import std/[json, os, strutils, unittest]

import codetracer_embed

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Record = "src/tests/visual/plat70b-gpui-window.json"
  LinePx = 20
    ## No text line is shorter than this many pixels (the tooltip's and the
    ## detail's lines are `HoverLabelPx` / a row's height).

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 40

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

proc arr(n: JsonNode): seq[int] =
  for v in n.getElems: result.add v.getInt

proc inside(box, rect: seq[int]): bool =
  box.len == 4 and rect.len == 4 and box[0] >= rect[0] and box[1] >= rect[1] and
    box[0] + box[2] <= rect[0] + rect[2] and box[1] + box[3] <= rect[1] + rect[3]

proc overlaps(box, rect: seq[int]): bool =
  box.len == 4 and rect.len == 4 and box[0] < rect[0] + rect[2] and
    rect[0] < box[0] + box[2] and box[1] < rect[1] + rect[3] and
    rect[1] < box[1] + box[3]

suite "PLAT-70 Part B: the GPUI window's table panes, read from its pixels":

  let rec = parseJson(readFile(repo / Record))
  let changed = rec["changed"]
  let aims = rec["aims"]
  let said = rec["reportedByWindow"]
  let ev = arr(rec["eventLogBody"])
  let evRect = arr(rec["eventLogRect"])
  let editor = arr(rec["editorBody"])
  let cell = arr(aims["cell"])
  let dots = arr(aims["ellipsis"])
  let rows = arr(aims["rows"])
  var columns: seq[tuple[name: string; x, w: int]] = @[]
  for c in aims["columns"].getElems:
    columns.add (c["column"].getStr, c["x"].getInt, c["w"].getInt)
  proc columnOf(name: string): tuple[name: string; x, w: int] =
    for c in columns:
      if c.name == name: return c

  test "every frame of the capture settled":
    var n = 0
    for k, v in rec["steps"]:
      checkpoint(k)
      ck v.getBool
      inc n
    ck n == 6

  test "the cut cell is the output's, its `…` drawn at its right edge":
    ck said["hover"].getStr.contains("cell hover eventLog output")
    let output = columnOf("output")
    ck cell[0] == output.x
    ck dots[1] <= cell[1]
    ck dots[0] >= cell[1] - 3 * LinePx
    ck rec["ellipsisInk"].getInt > 0

  test "§5.3: resting on the cut cell shows its whole text under it":
    let box = arr(changed["hover"])
    checkpoint($box)
    ck box.len == 4
    ck box[1] >= rows[1] - 1                # under the cell
    ck box[3] >= 2 * LinePx                 # wrapped: more than one line
    ck box[0] + box[2] <= rec["frame"][0].getInt
    ck said["tooltip"].getStr.contains("cell tooltip")

  test "§5.3: resting on a cell that fits shows nothing":
    ck changed["fits-hover"].kind == JNull
    ck not said["fitsTooltip"].getBool

  test "§5.3: the `…` press opens the detail under the row; the debugger stays":
    let box = arr(changed["detail"])
    checkpoint($box)
    ck box.len == 4
    ck box[1] >= rows[1] - 1
    ck box.inside(ev)
    ck box[3] >= 2 * LinePx
    ck box[0] >= columnOf("output").x       # in the output column
    ck said["detail"].getStr.contains("detail open eventLog")
    # The row under the press heard it first and left it to the table: no
    # jump — the tick the window reports is the one before the press.
    ck said["rowClick"].getStr.contains("left to the table gesture")
    ck said["tickAfterDetail"].getStr == said["tick"].getStr

  test "§5.3: pressed again, the detail closes":
    ck said["closed"].getStr.contains("detail closed eventLog")
    # What differs from the first frame is the Event Log taking the focus
    # (its strip and outline) — inside its own rect, nowhere near the editor.
    let box = arr(changed["closed"])
    ck box.len == 0 or box.inside(evRect)
    ck not box.overlaps(editor)

  test "§5.2: the `#` separator dragged — wider, remembered, not an order":
    let hash = columnOf("#")
    ck hash.w > 0
    ck said["separator"].getStr.contains("column separator #")
    # The edge follows the pointer from where the grip was taken: the column
    # is its drawn width plus the drag.
    let cells = said["dragCells"].getInt
    ck cells == cellsOfPx(hash.w + rec["dragPx"].getInt)
    ck cells > cellsOfPx(hash.w)
    ck said["remembered"].getStr.contains("event-log.#=" & $cells)
    let box = arr(changed["drag"])
    checkpoint($box)
    ck box.len == 4
    ck box.inside(ev)
    ck box[0] >= hash.x                     # what moved is right of its left
    # The header cell under the grip heard the press first and left it to
    # the separator: the log is not ordered by it.
    ck said["headerPress"].getStr.contains("left to the table gesture")
    ck said["orderedBy"].getStr.len == 0

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
