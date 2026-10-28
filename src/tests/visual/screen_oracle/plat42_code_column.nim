## Pixel-only code-column reader shared with the PLAT-42 record producer.
## Kept separate so tests exercise the producer's real predicate without
## executing its recording CLI or rewriting committed evidence.
import gui_assert/image_math
import ./region_locator

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
  let minWidth = 2 * (execution.y1 - execution.y0)
  var start = -1
  var tone = 0
  for x in left ..< right:
    let a = int(img.pixels[top * img.width + x])
    let b = int(img.pixels[bottom * img.width + x])
    let band = abs(a - b) <= GroundTolerance and
               abs(a - ground) >= MinBandContrast and
               abs(b - ground) >= MinBandContrast
    if band:
      if start < 0 or abs(a - tone) > GroundTolerance:
        start = x
        tone = a
      if x - start + 1 >= minWidth: return start
    else:
      start = -1
