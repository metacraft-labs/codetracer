## PLAT-45 — the arrangement the GPUI window OPENS WITH, read off its pixels.
##
## `ci/test/plat45-arrangement-window.sh` opens the windowed `codetracer-gpui`
## on `calc` with no remembered layout and frames it (`build/plat45/shared.ppm`)
## next to a BLANK compositor (`build/plat45/blank.ppm`). This program reads
## both frames with PLAT-39's pixel reader and nothing else — `locateGrid`
## finds the pane cells from the gutters, and OCR of each cell's top strip
## names what the cell holds: every pane box carries a tab strip since PLAT-49
## (one tab for a lone pane), and the ACTIVE tab is the one drawn on the
## selected tab's own ground (its label OCR'd on its own) — and writes
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
import ../../../frontend/gpui/chrome
import headless_app/layout_model

const
  RunDir = "build/plat45"
  Out = "src/tests/visual/plat45-gpui-arrangement.json"
  StripProbePx = TitleStripHeight + TitleRetryExtraPx
    ## How much of a cell's top is OCR'd for its strip: the tab strip the
    ## window draws for a stack, or a lone pane's heading.
  StripGroundHex = chromeOf(crTabStripBackground)
    ## The strip's own ground, read from the window's own colour table (since
    ## PLAT-50 ui/surface/primary/default, Dark; it was ui/surface/base/card
    ## spelled here as #262626).
  ActiveTabGroundHex = chromeOf(crTabActiveBackground)
    ## The selected tab's own ground (ui/surface/primary/tertiary, Dark).

proc isDocumentName(word: string): bool =
  ## A file name as a tab shows it: a stem, one dot, an extension of letters
  ## and digits (`main.py`, `calc.nim`).
  let dot = word.rfind('.')
  if dot <= 0 or dot >= word.len - 1:
    return false
  for c in word[0 ..< dot]:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.'}: return false
  for c in word[dot + 1 .. ^1]:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9'}: return false
  true

proc oneGlyphOff(a, b: string): bool =
  ## PLAT-50: `a` is `b` with at most one character misread — the same length,
  ## at most one position different, case aside, three characters or more.
  ## The OCR engine reads a dim label on the strip's ground
  ## (ui/surface/primary/default) with a glyph off now and then ("Cutput",
  ## "V(S"); a label is still read as itself, never as a different label (no
  ## two labels the window draws are one glyph apart).
  if a.len != b.len or a.len < 3:
    return false
  var diff = 0
  for i in 0 ..< a.len:
    if toLowerAscii(a[i]) != toLowerAscii(b[i]): inc diff
  diff <= 1

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
    if matched.len == 0 and i + 1 < words.len:
      for k in known:
        let parts = k.split(' ')
        if parts.len == 2 and
           (cmpIgnoreCase(parts[0], words[i]) == 0 or
            oneGlyphOff(words[i], parts[0])) and
           (cmpIgnoreCase(parts[1], words[i + 1]) == 0 or
            oneGlyphOff(words[i + 1], parts[1])):
          matched = k
    if matched.len > 0:
      result.add matched
      i += 2
      continue
    for k in known:
      if cmpIgnoreCase(k, words[i]) == 0: matched = k
    if matched.len == 0:
      for k in known:
        if not k.contains(' ') and oneGlyphOff(words[i], k): matched = k
    # A two-word label the OCR engine read as ONE word ("Eventlog"): since
    # PLAT-47 the window draws the ACTIVE tab bold, and tesseract closes the
    # gap of a bold two-word label. Matched with its space (and case) removed.
    if matched.len == 0:
      for k in known:
        if k.contains(' ') and
           cmpIgnoreCase(k.replace(" ", ""), words[i]) == 0:
          matched = k
    # A DOCUMENT'S TAB IS THE EDITOR (PLAT-49): a lone editor's tab names its
    # open file (`main.py`), as the desktop's editor tab does — the reading
    # `test_plat45_three_media.desktopPaneName` makes of the desktop's DOM
    # ("every document the editor opens is the editor pane"), made here of
    # the window's pixels.
    if matched.len == 0 and isDocumentName(words[i]):
      matched = gpuiPaneName(paneEditor)
    if matched.len > 0: result.add matched
    inc i

const FocusOutlineHex = "#3a3a3a"
  ## The colour the GPUI window outlines its focused region in. PLAT-47: the
  ## desktop's selected-panel outline, measured
  ## (`src/tests/visual/answers/plat47-desktop-parity.electron.json`,
  ## `focus.outline`, #565656); PLAT-51 (the user: the focus contrast
  ## SUBTLER) one step down the border ramp, ui/border/secondary
  ## (`chrome.crFocusOutline`). Read as a GRAY level, because the frame is
  ## decoded to gray.

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

proc ocrStrip(img: GrayImage; r: Rect; scratch: string): string =
  ## A tab strip's labels, read against the strip's two grounds
  ## (`vision_producer.ocrOnGrounds`).
  var words: seq[string] = @[]
  # PLAT-50: the pane's own ground too — the probe runs past the strip into
  # the pane's first rows, which were a solid black band in the mask.
  for w in ocrOnGrounds(img, r, scratch,
                        [grayOf(StripGroundHex), grayOf(ActiveTabGroundHex),
                         grayOf(chromeOf(crPaneBackground))]):
    words.add w.text
  words.join(" ").strip()

proc activeRun(img: GrayImage; r: Rect): Rect =
  ## The selected tab's own ground along the strip: the widest run of
  ## COLUMNS that carry the active tab's grey on at least `MinGroundRows` of
  ## the strip's rows. Counting rows per column, rather than reading one row,
  ## keeps a label's glyphs (lighter than the ground) from cutting the run:
  ## above and below the text every column of the tab is still its ground.
  const MinGroundRows = 3
  let want = grayOf(ActiveTabGroundHex)
  var best = (start: -1, len: 0)
  var start = -1
  for x in r.x .. r.x + r.w:
    var ground = 0
    if x < r.x + r.w and x < img.width:
      for y in r.y ..< min(r.y + r.h, img.height):
        if abs(int(img.pixels[y * img.width + x]) - want) <= 3: inc ground
    let inRun = ground >= MinGroundRows
    if inRun and start < 0: start = x
    if not inRun and start >= 0:
      if x - start > best.len: best = (start: start, len: x - start)
      start = -1
  if best.start < 0: return Rect()
  Rect(x: best.start, y: r.y, w: best.len, h: r.h)

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
    var top = cell.y
    var height = cell.h
    var stripRect = Rect(x: cell.x, y: cell.y, w: cell.w,
                         h: min(StripProbePx, cell.h))
    var strip = ocrStrip(img, stripRect, scratch)
    var tabs = labelsIn(strip)
    # PLAT-50: THE STRIP MAY BE OUTSIDE THE LOCATED CELL. The strip's ground
    # is the window's own (ui/surface/primary/default, the ground the
    # desktop's tabs sit on), so the grid locator, which finds cells by their
    # fill against that ground, can start a cell BELOW its strip. Then the
    # strip is the strip-high band just above the cell, probed as a cell's
    # own strip is (`StripProbePx` from the strip's top) — not higher, where
    # the top bar's menu-button border would be read as ink.
    if tabs.len == 0 and cell.y >= TitleStripHeight:
      let above = Rect(x: cell.x, y: cell.y - TitleStripHeight, w: cell.w,
                       h: StripProbePx)
      let alt = ocrStrip(img, above, scratch)
      if labelsIn(alt).len > 0:
        stripRect = above
        strip = alt
        tabs = labelsIn(alt)
        # The region is the strip and the cell under it.
        top = cell.y - TitleStripHeight
        height = cell.h + TitleStripHeight
    var heading = ""
    var active = ""
    if tabs.len >= 2:
      # A STACK: the strip names every tab, and the active one is the label
      # drawn on the selected tab's own ground — OCR'd on its own, so the
      # answer is still text a reader can check.
      let run = activeRun(img, stripRect)
      if run.w > 0:
        heading = ocrStrip(img, run, scratch)
        let under = labelsIn(heading)
        if under.len > 0: active = under[0]
    elif tabs.len == 1:
      active = tabs[0]
    regions.add %*{"x": cell.x, "y": top, "w": cell.w, "h": height,
                   "strip": strip, "tabs": tabs, "heading": heading,
                   "active": active,
                   "outline": outlineOf(img, cell.x, top, cell.w, height)}
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
