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
## The per-row difference is the fraction of pixels whose grey level moved by
## more than `PixelDelta`. Recorded raw; what the test asserts is WHICH rows
## differ, compared with the rows the ViewModel names.
##
## Run: `just plat42-window-record` (needs `tesseract`).

import std/[algorithm, json, os, strutils, tables, times, nativesockets]

import ./screen_reading
import ./domain_models
import ./vision_producer
import ./region_locator
import gui_assert/[image_math, ocr]

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

proc rowBands(img: GrayImage; pane: Rect; scratch: string): seq[RowBand] =
  ## One band per OCR'd text row that starts with a gutter number.
  let words = ocrRegion(img, pane, scratch)
  var groups = initOrderedTable[(int, int), seq[OcrWord]]()
  for w in words:
    groups.mgetOrPut((w.blockNum, w.lineNum), @[]).add w
  for _, ws0 in groups:
    var ws = ws0
    ws.sort(proc (a, b: OcrWord): int = cmp(a.bbox[0], b.bbox[0]))
    var digits = ""
    for ch in ws[0].text:
      if ch.isDigit: digits.add ch
      else: break
    if digits.len == 0: continue
    var y0 = high(int)
    var y1 = 0
    var parts: seq[string] = @[]
    for w in ws:
      y0 = min(y0, pane.y + w.bbox[1])
      y1 = max(y1, pane.y + w.bbox[1] + w.bbox[3])
      parts.add w.text
    result.add RowBand(line: parseInt(digits), y0: y0, y1: y1,
                       gutterRight: pane.x + ws[0].bbox[0] + ws[0].bbox[2],
                       text: parts.join(" "))

proc changedFraction(a, b: GrayImage; x0, x1, y0, y1: int): float =
  var moved, total = 0
  for y in max(0, y0) ..< min(min(a.height, b.height), y1):
    for x in max(0, x0) ..< min(min(a.width, b.width), x1):
      inc total
      let pa = int(a.pixels[y * a.width + x])
      let pb = int(b.pixels[y * b.width + x])
      if abs(pa - pb) > PixelDelta: inc moved
  if total == 0: 0.0 else: moved / total

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
    for b in rowBands(img, pane, scratch):
      rows.add %*{"line": b.line, "text": b.text}
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
