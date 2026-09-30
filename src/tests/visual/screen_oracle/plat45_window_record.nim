## PLAT-45 — the arrangement the GPUI window OPENS WITH, read off its pixels.
##
## `ci/test/plat45-arrangement-window.sh` opens the windowed `codetracer-gpui`
## on `calc` with no remembered layout and frames it (`build/plat45/shared.ppm`)
## next to a BLANK compositor (`build/plat45/blank.ppm`). This program reads
## both frames with PLAT-39's pixel reader and nothing else — `locateGrid`
## finds the pane cells from the gutters, and OCR of each cell's top strip
## names what the cell holds: one pane's heading, or a STACK's tab strip
## (then the heading under the strip names the ACTIVE tab) — and writes
## `src/tests/visual/plat45-gpui-arrangement.json`, which
## `src/frontend/tui/tests/test_plat45_three_media.nim` reduces to PLAT-20's
## relation and compares with the desktop's and the terminal's.
##
## NOTHING HERE READS THE APPLICATION: no dock document, no render plan, no
## `--dock-out`. The window's own `--dock-out` is what it was TOLD; this is
## what it DREW, which is the only reading that could have caught the window
## tiling every leaf in one row while the document described the arrangement.
##
## It REFUSES to write a record from absent frames: a record of "frame
## missing" would have the shape of an answer.
##
## Run: `just plat45-window-record` (needs `tesseract`; see PLAT-39).

import std/[json, math, nativesockets, os, strutils, times]

import ./screen_reading
import ./vision_producer
import ./region_locator
import gui_assert/image_math

import ../../../frontend/gpui/app/pane_names
import headless_app/layout_model

const
  RunDir = "build/plat45"
  Out = "src/tests/visual/plat45-gpui-arrangement.json"
  StripProbePx = TitleStripHeight + TitleRetryExtraPx
    ## How much of a cell's top is OCR'd for its strip: the tab strip the
    ## window draws for a stack, or a lone pane's heading.
  WindowTabStripPx = 30
    ## `gpui/main.TabStripPx`: where the active tab's own heading starts.

proc labelsIn(text: string): seq[string] =
  ## The pane labels a strip names, in reading order. Two-word labels
  ## ("Call Trace", "Event Log") are tried before one-word ones, so "Event Log"
  ## is not read as an unknown "Event" and an unknown "Log".
  var known: seq[string] = @[]
  for k in PaneKind: known.add gpuiPaneName(k)
  # Punctuation the engine hangs on a word ("Test Results." was read so on the
  # first frame) is not part of any label.
  var words: seq[string] = @[]
  for w in text.multiReplace(("[", " "), ("]", " "), ("|", " ")).splitWhitespace():
    let bare = w.strip(chars = PunctuationChars)
    if bare.len > 0: words.add bare
  var i = 0
  while i < words.len:
    var matched = ""
    if i + 1 < words.len:
      let two = words[i] & " " & words[i + 1]
      for k in known:
        if cmpIgnoreCase(k, two) == 0: matched = k
    if matched.len > 0:
      result.add matched
      i += 2
      continue
    for k in known:
      if cmpIgnoreCase(k, words[i]) == 0: matched = k
    # A two-word label the OCR engine read as ONE word ("Eventlog"): since
    # PLAT-47 the window draws the ACTIVE tab bold, and tesseract closes the
    # gap of a bold two-word label. Matched with its space (and case) removed.
    if matched.len == 0:
      for k in known:
        if k.contains(' ') and
           cmpIgnoreCase(k.replace(" ", ""), words[i]) == 0:
          matched = k
    if matched.len > 0: result.add matched
    inc i

const FocusOutlineHex = "#565656"
  ## PLAT-47: the desktop's selected-panel outline, measured
  ## (`src/tests/visual/answers/plat47-desktop-parity.electron.json`,
  ## `focus.outline`) — what the GPUI window must outline its focused region
  ## in. Read as a GRAY level, because the frame is decoded to gray.

proc grayOf(hex: string): int =
  ## The 8-bit luma ffmpeg's `gray` conversion gives an sRGB colour (BT.601).
  let r = parseHexInt(hex[1 .. 2]).float
  let g = parseHexInt(hex[3 .. 4]).float
  let b = parseHexInt(hex[5 .. 6]).float
  int(round(0.299 * r + 0.587 * g + 0.114 * b))

proc edgeOutlined(img: GrayImage; x0, y0, x1, y1: int; want: int): bool =
  ## Whether a line of pixels (inclusive ends, horizontal or vertical) is in
  ## the outline's gray along at least 90% of its length.
  var hits, total = 0
  let horizontal = y0 == y1
  let n = if horizontal: x1 - x0 + 1 else: y1 - y0 + 1
  for i in 0 ..< n:
    let x = if horizontal: x0 + i else: x0
    let y = if horizontal: y0 else: y0 + i
    if x < 0 or y < 0 or x >= img.width or y >= img.height: continue
    inc total
    if abs(int(img.pixels[y * img.width + x]) - want) <= 3: inc hits
  total > 0 and hits * 10 >= total * 9

proc outlineOf(img: GrayImage; x, y, w, h: int): JsonNode =
  ## PLAT-47: for each edge of a located cell, whether the focus outline runs
  ## along it — on the cell's own boundary line or the line just outside it
  ## (the reader's gutter search may or may not include the one-pixel frame).
  let want = grayOf(FocusOutlineHex)
  proc either(a, b: bool): bool = a or b
  %*{
    "top": either(edgeOutlined(img, x + 4, y, x + w - 5, y, want),
                  edgeOutlined(img, x + 4, y - 1, x + w - 5, y - 1, want)),
    "bottom": either(edgeOutlined(img, x + 4, y + h - 1, x + w - 5, y + h - 1, want),
                     edgeOutlined(img, x + 4, y + h, x + w - 5, y + h, want)),
    "left": either(edgeOutlined(img, x, y + 4, x, y + h - 5, want),
                   edgeOutlined(img, x - 1, y + 4, x - 1, y + h - 5, want)),
    "right": either(edgeOutlined(img, x + w - 1, y + 4, x + w - 1, y + h - 5, want),
                    edgeOutlined(img, x + w, y + 4, x + w, y + h - 5, want))}

proc ocrLine(img: GrayImage; r: Rect; scratch: string): string =
  ## One line of labels, upscaled 2x for the OCR engine (PLAT-42's row reader
  ## does the same): at 1x tesseract read the thin inactive "VCS" as "V(S"
  ## once the window named its font (measured 2026-09-29); at 2x every label
  ## of the first screen reads exactly, so no misreading is tolerated.
  var words: seq[string] = @[]
  for w in ocrRegion(img, r, scratch, psm = 7, upscale = 2.0):
    words.add w.text
  words.join(" ").strip()

proc readFrame(path, scratch: string): JsonNode =
  result = %*{"frame": path.extractFilename, "located": false, "reason": "",
              "width": 0, "height": 0, "regions": []}
  if not fileExists(path):
    result["reason"] = %("no file at " & path)
    return
  let img = decodeGray(path)
  result["width"] = %img.width
  result["height"] = %img.height
  let grid = locateGrid(img)
  if grid.isUnreadable:
    result["reason"] = %($grid.reason & ": " & grid.detail)
    return
  createDir(scratch)
  var regions = newJArray()
  for cell in grid.value.cells:
    let strip = ocrLine(img, Rect(x: cell.x, y: cell.y, w: cell.w,
                                  h: min(StripProbePx, cell.h)), scratch)
    let tabs = labelsIn(strip)
    var heading = ""
    var active = ""
    if tabs.len >= 2:
      # A STACK: the strip names every tab, and the active one is the pane
      # drawn under it — read from its own heading, not from the strip's
      # colour, so the answer is text a reader can check.
      heading = ocrLine(img, Rect(x: cell.x, y: cell.y + WindowTabStripPx,
                                  w: cell.w, h: min(StripProbePx,
                                    max(1, cell.h - WindowTabStripPx))),
                        scratch)
      let under = labelsIn(heading)
      if under.len > 0: active = under[0]
    elif tabs.len == 1:
      active = tabs[0]
    regions.add %*{"x": cell.x, "y": cell.y, "w": cell.w, "h": cell.h,
                   "strip": strip, "tabs": tabs, "heading": heading,
                   "active": active,
                   "outline": outlineOf(img, cell.x, cell.y, cell.w, cell.h)}
  result["regions"] = regions
  result["located"] = %(regions.len > 0)

proc main() =
  let root = getCurrentDir()
  for n in ["blank", "shared"]:
    if not fileExists(root / RunDir / (n & ".ppm")):
      quit("PLAT-45: refusing to record — frame " & n & " is missing " &
           "(`just plat45-arrangement-window` first)", 1)
  let manifest = root / RunDir / "manifest.jsonl"
  var settled = false
  if fileExists(manifest):
    for line in readFile(manifest).splitLines():
      if line.len == 0: continue
      let j = parseJson(line)
      if j["id"].getStr == "shared": settled = j["settled"].getBool
  if not settled:
    quit("PLAT-45: refusing to record — the window never settled", 1)
  let scratch = getTempDir() / "plat45-ocr"
  let record = %*{
    "_comment": [
      "PLAT-45 — the GPUI window's first screen on `calc` (no remembered",
      "layout) and a blank compositor, read through PLAT-39's pixel reader.",
      "Regenerate: `just plat45-arrangement-window` then",
      "`just plat45-window-record`. Asserted by test_plat45_three_media.nim."],
    "takenAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "host": getHostname(),
    "frames": {
      "shared": readFrame(root / RunDir / "shared.ppm", scratch),
      "blank": readFrame(root / RunDir / "blank.ppm", scratch)},
  }
  writeFile(root / Out, record.pretty & "\n")
  echo "wrote ", Out
  for r in record["frames"]["shared"]["regions"]:
    echo "  (", r["x"].getInt, ",", r["y"].getInt, " ", r["w"].getInt, "x",
      r["h"].getInt, ") tabs=", r["tabs"], " active=", r["active"].getStr,
      " strip='", r["strip"].getStr, "' outline=", r["outline"]
  echo "  blank: located=", record["frames"]["blank"]["located"].getBool,
    " ", record["frames"]["blank"]["reason"].getStr

main()
