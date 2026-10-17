## PLAT-42 — the four surfaces, READ OFF THE SCREEN, and their pixel twins.
##
## Reads the frames `ci/test/plat42-surfaces-window.sh` took (real
## `codetracer-gpui` windows on a headless sway) through PLAT-39's reader and
## writes `src/tests/visual/plat42-window.json`, which the portable suite
## `src/frontend/gpui/tests/test_plat42_window.nim` asserts over. Per frame:
##
##   * the EXECUTION LINE: the one line row whose execution-mark lane (left
##     of the number field) holds ink. PLAT-39's own reading (`readFrame` →
##     `EditorModel.higlitedLineNumber`, the band located by row medians) is
##     kept beside it as `plat39ExecutionLine` and asserted by nothing: since
##     the 2026-10-17 redesign the band is on the code column only, behind the
##     inline-value chips, and the reader misses it on three of six stops;
##   * the editor pane's LINE ROWS, one entry per row whose gutter shows a
##     number, with that line, the row's OCR'd text, whether its pointer lane
##     is inked, and its inline-value CHIPS — each found by its `#1b1b1b`
##     ground, its x from the code column, whether the "view more" eye cell
##     leads it, whether the pane's edge clips it, and its text OCR'd alone.
##
## And two PIXEL TWINS, each a pair of frames that differ in exactly one thing
## the ViewModel decides:
##
##   * `breakpoint-editor` vs `stepped-editor` — the same stop, with and
##     without a breakpoint: the MARGIN of each line (number, mark lanes,
##     chevron — the breakpoint lane is right of the number since the
##     redesign), compared;
##   * `noir-flow` vs `noir-flow-off` — the same stop, the flow overlay shown
##     and hidden: the CODE column of each line, compared. Lines are matched
##     by number, not by height: the overlay's loop control takes a row.
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
  Chip = object
    ## One inline value as the window paints it since the Electron redesign
    ## (2026-10-17): a rounded `#1b1b1b` box after the code, holding the
    ## name (#919191) and the value (#f3f3f3, bold), led by a 30 px `#333333`
    ## "view more" eye cell when the value is long.
    x0, x1: int
    more: bool
      ## The eye cell leads it (measured: 30 columns of `EyeGround`).
    clipped: bool
      ## It runs into the pane's right edge, so its text may be cut anywhere.
    text: string
      ## OCR of the box with the eye cell left out: `name value`.

  RowBand = object
    line: int
    y0, y1: int
    gutterRight: int
    codeX: int
      ## The code column's left: the margin (gutter, lanes, chevron) ends here.
    pointer: bool
    text: string
    chips: seq[Chip]

const
  ChipGround = 27
    ## `#1b1b1b`, the chip's ground. Measured on the frames: the editor's
    ## ground is 40 (`#282828`), the execution band's 64 (`#404040`), and
    ## every glyph's anti-aliasing blends toward a LIGHTER ink, so a pixel
    ## within `GroundTolerance` of 27 is a chip's and nothing else's.
  EyeGround = 51
    ## `#333333`, the "view more" cell's ground.
  GroundTolerance = 3
  MinChipPx = 12
    ## Narrower spans are a pane border or an indent guide, not a box.
  NumberFieldPx = 38
    ## The gutter's right-aligned number field (`leaves.GutterNumberPx`):
    ## left of it, in the margin, is the execution mark's lane only.
  CodePastNumberPx = 50
    ## Measured: the number's ink ends 49 px into the 110 px margin and the
    ## code starts at its end, 61 px further; the breakpoint lane, the trace
    ## lane and the fold chevron's ink all end within 50 px of the number.
    ## The code column's left is the leftmost ink past this, over all rows.

proc inkCount(img: GrayImage; x0, x1, y0, y1: int): int =
  ## Pixels more than 40 grey levels from the region's own most common level.
  var hist: array[256, int]
  let (ya, yb) = (max(0, y0), min(img.height, y1))
  let (xa, xb) = (max(0, x0), min(img.width, x1))
  if xb <= xa or yb <= ya: return 0
  for y in ya ..< yb:
    for x in xa ..< xb:
      inc hist[int(img.pixels[y * img.width + x])]
  var bg = 0
  for v in 1 .. 255:
    if hist[v] > hist[bg]: bg = v
  for y in ya ..< yb:
    for x in xa ..< xb:
      if abs(int(img.pixels[y * img.width + x]) - bg) > 40: inc result

proc firstInk(img: GrayImage; x0, x1, y0, y1: int): int =
  ## The leftmost column of `[x0, x1)` holding ink (as `inkCount` counts it,
  ## against the whole region's ground) in the rows, or -1.
  var hist: array[256, int]
  let (ya, yb) = (max(0, y0), min(img.height, y1))
  let (xa, xb) = (max(0, x0), min(img.width, x1))
  if xb <= xa or yb <= ya: return -1
  for y in ya ..< yb:
    for x in xa ..< xb:
      inc hist[int(img.pixels[y * img.width + x])]
  var bg = 0
  for v in 1 .. 255:
    if hist[v] > hist[bg]: bg = v
  for x in xa ..< xb:
    for y in ya ..< yb:
      if abs(int(img.pixels[y * img.width + x]) - bg) > 40: return x
  -1

proc chipsOf(img: GrayImage; pane: Rect; codeX, y0, y1: int;
             scratch: string): seq[Chip] =
  ## The row's chips, FOUND IN THE PIXELS by their ground and only then read.
  ## The row's own OCR cannot tell a chip from the code: they are spelled
  ## the same way (`results.append(value) results @[] value 5`) and the name
  ## of a value is, by construction, a word of the code on its line.
  let right = pane.x + pane.w - 2   # the pane's 1 px border reads as ground
  let h = y1 - y0
  proc near(v, target: int): bool = abs(v - target) <= GroundTolerance
  var ground = newSeq[bool](max(0, right - codeX))
  var eye = newSeq[bool](ground.len)
  for i in 0 ..< ground.len:
    let x = codeX + i
    var g, e = 0
    for y in max(0, y0) ..< min(img.height, y1):
      let v = int(img.pixels[y * img.width + x])
      if near(v, ChipGround): inc g
      elif near(v, EyeGround): inc e
    # A column of a chip shows its ground above or below the glyphs; the
    # eye cell fills the box's height with its own.
    ground[i] = g >= 2
    eye[i] = e * 5 >= h * 2
  var i = 0
  while i < ground.len:
    if not (ground[i] or eye[i]):
      inc i
      continue
    var j = i
    var eyeCols = 0
    var gap = 0
    while j < ground.len and gap <= 2:
      if ground[j] or eye[j]:
        gap = 0
        if eye[j]: inc eyeCols
      else:
        inc gap
      inc j
    let last = j - gap - 1
    if last - i + 1 >= MinChipPx and eyeCols < last - i + 1:
      var c = Chip(x0: codeX + i, x1: codeX + last,
                   more: eyeCols >= 20,
                   clipped: codeX + last >= right - 2)
      var textFrom = c.x0
      if c.more:
        var k = i
        while k <= last and not eye[k]: inc k
        while k <= last and eye[k]: inc k
        textFrom = codeX + k
      if c.x1 > textFrom:
        let words = ocrRegion(img, Rect(x: textFrom, y: y0, w: c.x1 - textFrom + 1,
                                        h: y1 - y0), scratch, psm = 7,
                              upscale = 2.0)
        var parts: seq[string] = @[]
        for w in words: parts.add w.text
        c.text = parts.join(" ")
      result.add c
    i = j

var lastVote: tuple[base, support, rows, nonLineRows: int]
  ## The last `rowBands` call's line-number vote, for the record.

proc rowBands(img: GrayImage; pane: Rect; scratch: string): seq[RowBand] =
  ## One band per LINE ROW of the editor pane — a row whose gutter carries a
  ## line number — with its line, its text, its chips and its pointer lane.
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
  # THE ROWS ARE A GRID OF SLOTS, FITTED; THE LINES ARE NOT. The editor
  # draws its rows at a fixed pitch (soft wrap is off), and ink runs are only
  # the EVIDENCE: the execution band merges with its neighbours into one
  # 30 px run, and per-row OCR misreads single digits (`2` as `7`, `69` as
  # `60`) — so neither a run nor a reading may define a row. Until the
  # 2026-10-17 redesign every slot was a line, and the grid was fitted as
  # `centre = a + b * line`. It is not any more: a sticky scroll header
  # takes the top slot with NO number, and the flow overlay's loop control
  # (`< iteration 0 from 5 >`) takes a slot of its own between two lines —
  # measured, every line below it was then labelled one too high. So the
  # grid is fitted over SLOT indices, a slot is a line row when its number
  # field holds ink, and the line rows are labelled by the MAJORITY of
  # `reading - line-row index`. The vote and its support are recorded, and
  # the suite requires a majority.
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
  # LEAST-SQUARES over the readings' slots, `centre = a + b * slot`, then
  # again without the readings it leaves more than a quarter pitch out. A
  # median step drifted by a few pixels over fifty rows — enough to crop
  # through the glyphs of line 44.
  proc fit(keep: proc (c: float; k: int): bool): (float, float) =
    var sx, sy, sxx, sxy, n = 0.0
    for r in reads:
      let k = int(round((r.centre - origin) / pitch))
      if keep(r.centre, k):
        let x = float(k)
        sx += x
        sy += r.centre
        sxx += x * x
        sxy += x * r.centre
        n += 1
    let b = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    ((sy - b * sx) / n, b)
  var (a, b) = fit(proc (c: float; k: int): bool = true)
  let (a0, b0) = (a, b)
  (a, b) = fit(proc (c: float; k: int): bool =
    abs(c - (a0 + b0 * float(k))) <= pitch / 4)
  var rights: seq[int] = @[]
  for r in reads: rights.add r.right
  rights.sort()
  let gutterRight = rights[rights.len div 2]
  # The slots, and which of them are line rows.
  var slots: seq[tuple[k, y0, y1: int, isLine: bool, j: int]] = @[]
  var k = int(ceil((float(body.y) + b / 2 - a) / b))
  var lineRows = 0
  while a + b * float(k) + b / 2 <= float(yEnd):
    let centre = a + b * float(k)
    let y0 = int(round(centre - b / 2))
    let y1 = int(round(centre + b / 2))
    let isLine = inkCount(img, gutterRight - NumberFieldPx, gutterRight + 1,
                          y0 + 1, y1 - 1) > 0
    slots.add (k, y0, y1, isLine, (if isLine: lineRows else: -1))
    if isLine: inc lineRows
    inc k
  var votes = initCountTable[int]()
  for r in reads:
    let rk = int(round((r.centre - a) / b))
    for s in slots:
      if s.k == rk and s.isLine:
        votes.inc(r.number - s.j)
  if votes.len == 0: return
  let (base, support) = votes.largest
  var codeX = pane.x + pane.w
  for s in slots:
    if s.isLine:
      let f = firstInk(img, gutterRight + CodePastNumberPx, pane.x + pane.w - 2,
                       s.y0 + 1, s.y1 - 1)
      if f >= 0: codeX = min(codeX, f)
  lastVote = (base, support, reads.len, slots.len - lineRows)
  for s in slots:
    if not s.isLine: continue
    let rowRect = Rect(x: pane.x, y: s.y0, w: pane.w, h: s.y1 - s.y0)
    # 2x for the row's TEXT: at 1x tesseract collapses doubled characters
    # at this size.
    let words = ocrRegion(img, rowRect, scratch, psm = 7, upscale = 2.0)
    var parts: seq[string] = @[]
    for w in words: parts.add w.text
    # THE POINTER is the execution mark in its own lane, left of the number
    # field (`leaves.GutterPointerPx`). PLAT-39's reader looks for the
    # execution band instead — a row whose MEDIAN grey differs — and since
    # the redesign that band is drawn only on the code column, behind the
    # code and the chips: measured, it is a minority of the row whenever the
    # row carries a long chip, and the reader then reports no execution line
    # (`stepped-editor`, `advanced-state`, `continued-event-log`).
    let pointer = inkCount(img, pane.x, gutterRight - NumberFieldPx,
                           s.y0 + 1, s.y1 - 1) > 0
    result.add RowBand(line: base + s.j, y0: s.y0, y1: s.y1,
                       gutterRight: gutterRight, codeX: codeX,
                       pointer: pointer,
                       text: parts.join(" "),
                       chips: chipsOf(img, pane, codeX, s.y0, s.y1, scratch))

proc changedFraction(a, b: GrayImage; x0, x1, ay0, by0, h: int): float =
  ## The fraction of the region's INK that moved: pixels whose grey level
  ## differs by more than `PixelDelta` between the frames, over pixels that
  ## are ink (differ from the region's background by more than `PixelDelta`)
  ## in either frame. Normalised by ink rather than by area because a row
  ## holding one `}` has a hundredth of the ink of a full line, and an
  ## area-normalised change on it measured 0.011 — indistinguishable from
  ## noise — while its glyph was plainly dimmed.
  ##
  ## The row may sit at a different height in each frame (`ay0`, `by0`):
  ## the flow overlay's loop control takes a row of its own, so with the
  ## overlay hidden every line below it is drawn one row higher.
  var hist: array[256, int]
  let xa = max(0, x0)
  let xb = min(min(a.width, b.width), x1)
  var rows: seq[int] = @[]
  for dy in 0 ..< h:
    if ay0 + dy in 0 ..< a.height and by0 + dy in 0 ..< b.height: rows.add dy
  for dy in rows:
    for x in xa ..< xb:
      inc hist[int(b.pixels[(by0 + dy) * b.width + x])]
  var bg = 0
  for v in 1 .. 255:
    if hist[v] > hist[bg]: bg = v
  var moved, ink = 0
  for dy in rows:
    for x in xa ..< xb:
      let pa = int(a.pixels[(ay0 + dy) * a.width + x])
      let pb = int(b.pixels[(by0 + dy) * b.width + x])
      if abs(pa - bg) > PixelDelta or abs(pb - bg) > PixelDelta:
        inc ink
        if abs(pa - pb) > PixelDelta: inc moved
  if ink == 0: 0.0 else: moved / ink

proc editorRect(img: GrayImage; scratch: string): (bool, Rect) =
  ## The editor's cell. PLAT-39's classifier knows the editor by its title —
  ## `Editor`, or a Python file (`.PY`) — and since the redesign the GPUI
  ## editor is titled with the open file's PATH, as the desktop's is: for
  ## `noir_space_ship` that is `src/shield.nr`, which it classifies as
  ## nothing. A cell no class claimed, whose title's first word is a path to
  ## a file with an extension, is the editor here — when exactly one cell is.
  ## (The rest of the strip is the tab's pin and close icons, measured to OCR
  ## as `sro/shield.nr X`.)
  let grid = locateGrid(img)
  if grid.isUnreadable: return (false, Rect())
  var byPath: seq[Rect] = @[]
  for cell in grid.value.cells:
    let pane = identifyPane(img, cell, scratch)
    if pane.id == piEditor: return (true, pane.rect)
    if pane.id in {piOther, piUnknown}:
      let words = pane.titleText.splitWhitespace()
      let t = if words.len > 0: words[0] else: ""
      let dot = t.rfind('.')
      if dot > 0 and dot < t.high and
         t[dot + 1 .. ^1].allCharsInSet(Letters):
        byPath.add pane.rect
  if byPath.len == 1: return (true, byPath[0])
  (false, Rect())

proc frameJson(path, scratch: string): JsonNode =
  result = %*{"frame": path.extractFilename, "present": fileExists(path)}
  if not fileExists(path): return
  let reading = readFrame(path, scratch)
  # PLAT-39's own reading, recorded as it came back and asserted by nothing:
  # see `rowBands` for why it no longer finds the execution band.
  result["plat39ExecutionLine"] =
    if reading.editor.kind == srRead: %reading.editor.value.higlitedLineNumber
    else: %(-1)
  let img = decodeGray(path)
  let (found, pane) = editorRect(img, scratch)
  result["editorLocated"] = %found
  var rows = newJArray()
  var pointerLines: seq[int] = @[]
  if found:
    lastVote = (0, 0, 0, 0)
    for b in rowBands(img, pane, scratch):
      # `codeWidth`: how much code column the pane shows — a value placed
      # further right than this is legitimately not on screen.
      result["codeWidth"] = %(pane.x + pane.w - 2 - b.codeX)
      var chips = newJArray()
      for c in b.chips:
        # `x`: the box's left, in px from the code column's left.
        chips.add %*{"x": c.x0 - b.codeX, "text": c.text, "more": c.more,
                     "clipped": c.clipped}
      rows.add %*{"line": b.line, "pointer": b.pointer, "text": b.text,
                  "chips": chips}
      if b.pointer: pointerLines.add b.line
    result["lineVote"] = %*{"firstLine": lastVote.base + 0,
                             "support": lastVote.support,
                             "rows": lastVote.rows,
                             "nonLineRows": lastVote.nonLineRows}
  # THE EXECUTION LINE: the one line row whose pointer lane holds ink, or -1
  # when none or more than one does (`pointerLines` carries them all).
  result["pointerLines"] = %pointerLines
  result["executionLine"] =
    if pointerLines.len == 1: %pointerLines[0] else: %(-1)
  result["rows"] = rows

proc twin(withPath, withoutPath: string; region: string;
          scratch: string): JsonNode =
  ## Per-LINE changed fraction between two frames, over the margin (gutter
  ## and lanes) or the code column of each line row. Each frame's rows are
  ## its own (`rowBands`), matched by line; a line drawn in only one of the
  ## two frames is not compared.
  result = newJArray()
  if not (fileExists(withPath) and fileExists(withoutPath)): return
  let a = decodeGray(withPath)
  let b = decodeGray(withoutPath)
  let (foundA, paneA) = editorRect(a, scratch)
  let (foundB, pane) = editorRect(b, scratch)
  if not (foundA and foundB) or paneA != pane: return
  let bandsA = rowBands(a, paneA, scratch)
  for band in rowBands(b, pane, scratch):
    for other in bandsA:
      if other.line != band.line: continue
      let (x0, x1) =
        if region == "gutter": (pane.x, band.codeX - 1)
        else: (band.codeX, pane.x + pane.w - 2)
      result.add %*{"line": band.line,
                    "changed": changedFraction(a, b, x0, x1, other.y0, band.y0,
                                               band.y1 - band.y0)}

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
