## Pixel-only code-column reader shared with the PLAT-42 record producer.
## Kept separate so tests exercise the producer's real predicate without
## executing its recording CLI or rewriting committed evidence.
import gui_assert/image_math
import ./region_locator

const PointerLaneSlackPx* = 2
    ## The pointer lane's left edge is read 2 px early: the editor's cell is
    ## located from the frame's separators, which may land a column off the
    ## editor's own left. The glyph lane's breakpoint disc stops 7 px short of
    ## the lane.

proc inkCount*(img: GrayImage; x0, x1, y0, y1: int): int =
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

proc pointerLane*(img: GrayImage; pane: Rect; rowPx: int): tuple[x0, x1: int] =
  ## THE EXECUTION POINTER'S LANE, in frame pixels, FROM THE PIXELS: right of
  ## the glyph margin and left of the line-number column.
  ##
  ## - The glyph margin (breakpoints, tracepoints) is Monaco's, one line
  ##   height wide (`glyphMarginWidth`), and both front-ends draw it so. A
  ##   line height is a row's pitch, which the reader measures, so the lane
  ##   starts `rowPx` right of the pane's left.
  ## - The line numbers are the first columns, right of that, holding ink on
  ##   more than one row's worth of scanlines: the pointer is drawn on one
  ##   row, a number on every row.
  ##
  ## This reader once took the lane from the application's own band map
  ## (`viewmodel/viewmodels/editor_gutter_lanes`), which made "the pointer is
  ## in its lane" a second reading of the map it was meant to check, and
  ## broke PLAT-39's LAW-R4 (the oracle imports nothing from `viewmodel/`).
  ## `test_plat42_window_reader.nim` is where the two are compared.
  let x0 = pane.x + rowPx - PointerLaneSlackPx
  let (ya, yb) = (max(0, pane.y), min(img.height, pane.y + pane.h))
  var x1 = x0
  let xEnd = min(img.width, pane.x + pane.w div 2)
  while x1 < xEnd and inkCount(img, x1, x1 + 1, ya, yb) <= rowPx: inc x1
  (x0, x1)

proc pointerInked*(img: GrayImage; pane: Rect; y0, y1: int): bool =
  ## Whether the row between `y0` and `y1` carries the execution mark: ink in
  ## its `pointerLane`, its edge scanlines left out (a neighbour's
  ## anti-aliasing).
  let lane = pointerLane(img, pane, y1 - y0)
  inkCount(img, lane.x0, lane.x1, y0 + 1, y1 - 1) > 0

type CodeColumnRow* = object
  y0*, y1*: int
  pointer*: bool

proc codeColumnLeft*(img: GrayImage; pane: Rect; gutterRight: int;
                     rows: openArray[CodeColumnRow]): int =
  ## Read the execution background's left edge, or -1 when it is unreadable.
  ##
  ## Ink is not a boundary: folding controls can occur anywhere in the gutter,
  ## and indentation moves the first source glyph away from the code edge.
  ## The execution pointer identifies the row whose code background is shaded.
  ## Its top and bottom whitespace expose that band without sampling text,
  ## folding ink or inline chips. The reference ground is measured from that
  ## same row's number margin, rather than copied from the renderer's palette.
  ## A band must span at least two row heights, excluding thin full-height VCS
  ## indicators. Missing evidence stays missing; callers must refuse a record.
  result = -1
  if img.width <= 0 or img.height <= 0 or
     img.pixels.len != img.width * img.height: return
  var pointerRows = 0
  var execution: CodeColumnRow
  for row in rows:
    if row.pointer:
      inc pointerRows
      execution = row
  if pointerRows != 1 or execution.y1 - execution.y0 < 4: return
  let top = execution.y0 + 1
  let bottom = execution.y1 - 2
  if top < 0 or bottom >= img.height: return
  let left = max(0, pane.x)
  let right = min(img.width, pane.x + pane.w - 2)
  let numberRight = min(right, gutterRight + 1)
  if numberRight <= left: return
  var histogram: array[256, int]
  for x in left ..< numberRight:
    inc histogram[int(img.pixels[top * img.width + x])]
    inc histogram[int(img.pixels[bottom * img.width + x])]
  var ground = 0
  for gray in 1 .. 255:
    if histogram[gray] > histogram[ground]: ground = gray
  const
    GroundTolerance = 3
    MinBandContrast = 16
    MaxCrossingPx = 2
      ## The widest full-height line the editor draws ACROSS the band: the
      ## indent guides are 1 px and the caret 2 px (`leaves.renderEditorRow`).
      ## A guide sits one indentation level into the code, so on an indented
      ## execution row it cut the band 3 px in, the band restarted after it,
      ## and the code column was read 40 px too far right
      ## (`returned-calltrace`, `noir-flow`). A crossing that narrow does not
      ## end the band; anything wider does.
  let minWidth = 2 * (execution.y1 - execution.y0)
  var start = -1
  var tone = 0
  var lastBand = -1
  var otherStart = -1   # where a run of ANOTHER band tone began, if one is on
  var otherTone = 0
  for x in left ..< right:
    let a = int(img.pixels[top * img.width + x])
    let b = int(img.pixels[bottom * img.width + x])
    let band = abs(a - b) <= GroundTolerance and
               abs(a - ground) >= MinBandContrast and
               abs(b - ground) >= MinBandContrast
    if band and (start < 0 or abs(a - tone) <= GroundTolerance):
      if start < 0:
        start = x
        tone = a
      lastBand = x
      otherStart = -1
    else:
      # Off the band's tone: a crossing (a guide is drawn in its own grey,
      # which reads as a band of another tone) or the band's end.
      if band:
        if otherStart < 0 or abs(a - otherTone) > GroundTolerance:
          otherStart = x
          otherTone = a
      else:
        otherStart = -1
      if start >= 0 and x - lastBand > MaxCrossingPx:
        start = otherStart
        tone = otherTone
        lastBand = x
        otherStart = -1
    if start >= 0 and lastBand == x and x - start + 1 >= minWidth:
      return start
