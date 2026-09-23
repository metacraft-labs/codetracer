## PLAT-42 — the four surfaces, READ OFF THE SCREEN, and their pixel twins.
##
## Reads the frames `ci/test/plat42-surfaces-window.sh` took (real
## `codetracer-gpui` windows on a headless sway) through PLAT-39's reader and
## writes `src/tests/visual/plat42-window.json`, which the portable suite
## `src/frontend/gpui/tests/test_plat42_window.nim` asserts over. Per frame:
##
##   * the EXECUTION LINE as PLAT-39 recovers it from pixels (`readFrame` →
##     `EditorModel.higlitedLineNumber`: the highlighted band located
##     geometrically, its gutter OCR'd);
##   * the editor pane's text, OCR'd, one entry per text row with the row's
##     gutter number and its pixel band — which is where the inline values'
##     text is read.
##
## And two PIXEL TWINS, each a pair of frames that differ in exactly one thing
## the ViewModel decides:
##
##   * `breakpoint-editor` vs `stepped-editor` — the same stop, with and
##     without a breakpoint: the GUTTER band of each row, compared;
##   * `noir-flow` vs `noir-flow-off` — the same stop, the flow overlay shown
##     and hidden: the CODE band of each row, compared.
##
## The per-row difference is the fraction of the row's INK whose grey level
## moved by more than `PixelDelta` (see `changedFraction`). Recorded raw; what
## the test asserts is WHICH rows differ, compared with the rows the ViewModel
## names.
##
## Run: `just plat42-window-record` (needs `tesseract`).

import std/[algorithm, json, math, os, strutils, tables, times, nativesockets]

import ./screen_reading
import ./domain_models
import ./vision_producer
import ./region_locator
import gui_assert/[image_math, ocr]
import ../../../frontend/gpui/tests/plat42_gutter

const
  RunDir = "build/plat42-window"
  Out = "src/tests/visual/plat42-window.json"
  PixelDelta = 16
    ## Grey levels. Below it is the rasteriser's noise between two renders of
    ## the same thing; the twins' untouched rows measure it.

type
  RowBand = object
    line: int
    y0, y1: int
    gutterRight: int
    text: string

proc editorRect(img: GrayImage; scratch: string): (bool, Rect) =
  let grid = locateGrid(img)
  if grid.isUnreadable: return (false, Rect())
  for cell in grid.value.cells:
    let pane = identifyPane(img, cell, scratch)
    if pane.id == piEditor: return (true, pane.rect)
  (false, Rect())

var lastVote: tuple[base, support, rows: int]
  ## The last `rowBands` call's line-number vote, for the record.

proc rowBands(img: GrayImage; pane: Rect; scratch: string): seq[RowBand] =
  ## One band per text ROW of the editor pane whose gutter reads as a line
  ## number.
  ##
  ## **ROWS ARE FOUND IN THE PIXELS, NOT BY OCR.** The first two versions of
  ## this record grouped the words of one whole-pane OCR — by tesseract's
  ## block/line numbers (which split the gutter column from the code), then by
  ## vertical position — and both were only as good as that one OCR: at
  ## 1920x1080 it dropped lines 2 and 5 outright, so the per-line-status twin
  ## never measured the breakpoint's line. Here a row is a run of scanlines
  ## holding ink (a pixel more than 40 grey levels from its scanline's
  ## median, which is the row's own background — the execution band's too);
  ## its LINE is read from its own gutter cell by `readGutterDigits`, the rule
  ## the editor reader uses; its TEXT by OCR of that row alone.
  let body = bodyBelowTitle(pane)
  let x0 = pane.x + 2
  let x1 = min(img.width, pane.x + pane.w - 2)
  let medians = rowMedians(img, x0, x1 - 1)
  proc inked(y: int): bool =
    for x in x0 ..< x1:
      if abs(int(img.pixels[y * img.width + x]) - medians[y]) > 40:
        return true
    false
  var runs: seq[GutterRun] = @[]
  var y = body.y
  let yEnd = min(img.height, body.y + body.h)
  while y < yEnd:
    if inked(y):
      var j = y
      var gap = 0
      while j < yEnd and gap <= 2:
        if inked(j): gap = 0
        else: inc gap
        inc j
      runs.add GutterRun(first: y, last: j - gap - 1)
      y = j
    else:
      inc y
  # THE ROWS ARE A GRID, FITTED. The editor draws one row per consecutive
  # line at a fixed pitch (soft wrap is off; `leaves.renderEditorRow`). Ink
  # runs are only the EVIDENCE: measured, the execution band merges with its
  # neighbours into one 30 px run, and per-row OCR misreads single digits
  # (`2` as `7`, `69` as `60`) — so neither a run nor a reading may define a
  # row. From the runs whose gutter reads, the pitch is the median spacing of
  # consecutive readings one line apart, and the grid's first line is the
  # MAJORITY of `reading - grid index`. Every row below is a grid row; the
  # vote and its support are recorded, and the suite requires a majority.
  var heights: seq[int] = @[]
  for run in runs:
    if run.last - run.first >= 5: heights.add run.last - run.first + 1
  if heights.len == 0: return
  heights.sort()
  let typicalHeight = heights[heights.len div 2]
  var reads: seq[tuple[centre: float, number, right: int]] = @[]
  for run in runs:
    let h = run.last - run.first + 1
    if h < 6 or h * 2 > typicalHeight * 3: continue
    let g = readGutterDigits(img, pane, run, scratch)
    if g.ok:
      reads.add ((run.first + run.last) / 2, g.line, g.right)
  if reads.len < 3: return
  var steps: seq[float] = @[]
  for i in 1 ..< reads.len:
    if reads[i].number - reads[i - 1].number == 1:
      steps.add reads[i].centre - reads[i - 1].centre
  if steps.len == 0: return
  steps.sort()
  let pitch = steps[steps.len div 2]
  let origin = reads[0].centre
  var votes = initCountTable[int]()
  for r in reads:
    votes.inc(r.number - int(round((r.centre - origin) / pitch)))
  let (vote, support) = votes.largest
  # THE GRID, LEAST-SQUARES over the readings that agree with the vote:
  # `centre = a + b * line`. A median step drifted by a few pixels over fifty
  # rows — enough to crop through the glyphs of line 44.
  var sx, sy, sxx, sxy, n = 0.0
  for r in reads:
    if r.number - int(round((r.centre - origin) / pitch)) == vote:
      let x = float(r.number)
      sx += x
      sy += r.centre
      sxx += x * x
      sxy += x * r.centre
      n += 1
  let b = (n * sxy - sx * sy) / (n * sxx - sx * sx)
  let a = (sy - b * sx) / n
  var rights: seq[int] = @[]
  for r in reads: rights.add r.right
  rights.sort()
  let gutterRight = rights[rights.len div 2]
  var line = max(1, int(ceil((float(body.y) + b / 2 - a) / b)))
  lastVote = (line, support, reads.len)
  while a + b * float(line) + b / 2 <= float(yEnd):
    let centre = a + b * float(line)
    let y0 = int(round(centre - b / 2))
    let y1 = int(round(centre + b / 2))
    let rowRect = Rect(x: pane.x, y: y0, w: pane.w, h: y1 - y0)
    # 2x for the row's TEXT: at 1x tesseract collapses doubled characters
    # at this size, and the text is where an inline value's name is read.
    let words = ocrRegion(img, rowRect, scratch, psm = 7, upscale = 2.0)
    var parts: seq[string] = @[]
    for w in words: parts.add w.text
    if parts.len > 0:
      result.add RowBand(line: line, y0: y0, y1: y1,
                         gutterRight: gutterRight, text: parts.join(" "))
    inc line

proc changedFraction(a, b: GrayImage; x0, x1, y0, y1: int): float =
  ## The fraction of the region's INK that moved: pixels whose grey level
  ## differs by more than `PixelDelta` between the frames, over pixels that
  ## are ink (differ from the region's background by more than `PixelDelta`)
  ## in either frame. Normalised by ink rather than by area because a row
  ## holding one `}` has a hundredth of the ink of a full line, and an
  ## area-normalised change on it measured 0.011 — indistinguishable from
  ## noise — while its glyph was plainly dimmed.
  var hist: array[256, int]
  for y in max(0, y0) ..< min(min(a.height, b.height), y1):
    for x in max(0, x0) ..< min(min(a.width, b.width), x1):
      inc hist[int(b.pixels[y * b.width + x])]
  var bg = 0
  for v in 1 .. 255:
    if hist[v] > hist[bg]: bg = v
  var moved, ink = 0
  for y in max(0, y0) ..< min(min(a.height, b.height), y1):
    for x in max(0, x0) ..< min(min(a.width, b.width), x1):
      let pa = int(a.pixels[y * a.width + x])
      let pb = int(b.pixels[y * b.width + x])
      if abs(pa - bg) > PixelDelta or abs(pb - bg) > PixelDelta:
        inc ink
        if abs(pa - pb) > PixelDelta: inc moved
  if ink == 0: 0.0 else: moved / ink

proc frameJson(path, scratch: string): JsonNode =
  result = %*{"frame": path.extractFilename, "present": fileExists(path)}
  if not fileExists(path): return
  let reading = readFrame(path, scratch)
  result["executionLine"] =
    if reading.editor.kind == srRead: %reading.editor.value.higlitedLineNumber
    else: %(-1)
  let img = decodeGray(path)
  let (found, pane) = editorRect(img, scratch)
  result["editorLocated"] = %found
  var rows = newJArray()
  if found:
    lastVote = (0, 0, 0)
    for b in rowBands(img, pane, scratch):
      rows.add %*{"line": b.line, "text": b.text}
    result["lineVote"] = %*{"firstLine": lastVote.base + 0,
                             "support": lastVote.support,
                             "rows": lastVote.rows}
  result["rows"] = rows

proc twin(withPath, withoutPath: string; region: string;
          scratch: string): JsonNode =
  ## Per-row changed fraction between two frames, over the gutter band or the
  ## code band of each row. Bands come from the WITHOUT frame's OCR.
  result = newJArray()
  if not (fileExists(withPath) and fileExists(withoutPath)): return
  let a = decodeGray(withPath)
  let b = decodeGray(withoutPath)
  let (found, pane) = editorRect(b, scratch)
  if not found: return
  for band in rowBands(b, pane, scratch):
    let (x0, x1) =
      if region == "gutter": (pane.x, band.gutterRight + 2)
      else: (band.gutterRight + 4, pane.x + pane.w - 2)
    result.add %*{"line": band.line,
                  "changed": changedFraction(a, b, x0, x1, band.y0, band.y1)}

proc main() =
  let root = getCurrentDir()
  let run = root / RunDir
  if not fileExists(run / "manifest.jsonl"):
    quit("PLAT-42: refusing to record — no window run at " & run, 1)
  let scratch = getTempDir() / "plat42-window-ocr"
  var manifest = newJArray()
  for line in lines(run / "manifest.jsonl"):
    if line.strip.len > 0: manifest.add parseJson(line)
  var frames = newJObject()
  for m in manifest:
    let id = m["id"].getStr
    frames[id] = frameJson(run / (id & ".ppm"), scratch)
  let record = %*{
    "_comment": [
      "PLAT-42 — the four surfaces read off real GPUI windows through PLAT-39's",
      "reader, and two pixel twins. Regenerate: `just plat42-surfaces-window`",
      "then `just plat42-window-record`. Asserted by test_plat42_window.nim."],
    "takenAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "host": getHostname(),
    "pixelDelta": PixelDelta,
    "manifest": manifest,
    "frames": frames,
    "markTwin": twin(run / "breakpoint-editor.ppm", run / "stepped-editor.ppm",
                     "gutter", scratch),
    "flowTwin": twin(run / "noir-flow.ppm", run / "noir-flow-off.ppm",
                     "code", scratch),
  }
  writeFile(root / Out, record.pretty & "\n")
  echo "wrote ", Out

main()
