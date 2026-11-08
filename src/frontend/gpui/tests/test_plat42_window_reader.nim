## The PLAT-42 window record's two layout readings, on controlled grayscale
## rasters: the execution pointer's lane, and the pane split that must not
## take the editor's sticky-scroll shadow for a splitter.
##
## Synthetic images, not mocked readers: every case calls the helper the
## record producer (`plat42_window_record.nim`) calls. The tones are the
## window's, measured on the `stepped-editor` and `breakpoint-editor` frames
## at codetracer `b7e12b7450b`: editor ground 40, gutter 27, execution arrow
## 196 (`#FACC15`), breakpoint disc ~90, the sticky shadow's rows 31/21/31/37.
## The real frames are what `test_plat42_window.nim` reads; these cases pin
## each rule apart from OCR and the GPU, with a planted regression beside
## every accepting case.
import std/unittest
import gui_assert/image_math
import ../../../tests/visual/screen_oracle/[region_locator, plat42_code_column]
import ../chrome
import ../../viewmodel/viewmodels/editor_gutter_lanes

const
  Ground = 40
  Gutter = 27
  Pane = Rect(x: 4, y: 0, w: 300, h: 88)
  RowPx = 22

proc blank(w, h: int; gray = Ground): GrayImage =
  result = GrayImage(width: w, height: h, pixels: newString(w * h))
  for i in 0 ..< w * h: result.pixels[i] = char(gray)

proc rect(img: var GrayImage; x0, x1, y0, y1: int; gray: int) =
  for y in y0 ..< y1:
    for x in x0 ..< x1: img.pixels[y * img.width + x] = char(gray)

proc gutterFrame(arrowRow, discRow: int): GrayImage =
  ## Four editor rows. The arrow (7x9) at the pointer lane's left edge on
  ## `arrowRow`, the breakpoint disc (9 px) centred in the glyph lane on
  ## `discRow`, a line number right of both on every row; -1 draws none.
  result = blank(Pane.x + Pane.w, Pane.h)
  let glyph = gbGlyph.widthPx(CodeFontPx)
  for row in 0 ..< 4:
    let y = row * RowPx
    result.rect(Pane.x + 64, Pane.x + 80, y + 5, y + 17, 180)  # the number
    if row == arrowRow:
      result.rect(Pane.x + glyph, Pane.x + glyph + 7, y + 6, y + 15, 196)
    if row == discRow:
      let left = Pane.x + (glyph - 9) div 2
      result.rect(left, left + 9, y + 6, y + 15, 90)

proc pointerRows(img: GrayImage): seq[int] =
  for row in 0 ..< 4:
    if pointerInked(img, Pane, row * RowPx, (row + 1) * RowPx): result.add row

suite "PLAT-42 window reader: the execution pointer's lane":
  test "the lane is the shared map's pointer band, right of the glyph lane":
    let lane = pointerLane(Pane)
    let glyph = gbGlyph.widthPx(CodeFontPx)
    check lane.x0 == Pane.x + glyph - PointerLaneSlackPx
    check lane.x1 == Pane.x + glyph + gbPointer.widthPx(CodeFontPx)

  test "the arrow's row is the one pointer row":
    check pointerRows(gutterFrame(arrowRow = 2, discRow = -1)) == @[2]

  test "a breakpoint in the glyph lane is not a second pointer":
    # The defect: read as "ink left of the number field", the disc's row was
    # an execution line too, and the record refused `breakpoint-editor`.
    check pointerRows(gutterFrame(arrowRow = 2, discRow = 1)) == @[2]
    check pointerRows(gutterFrame(arrowRow = 2, discRow = 2)) == @[2]

  test "planted: the pointer moved is read where it moved to":
    check pointerRows(gutterFrame(arrowRow = 0, discRow = 1)) == @[0]
    check pointerRows(gutterFrame(arrowRow = 3, discRow = 1)) == @[3]

  test "planted: no arrow, no pointer — a disc alone is not one":
    check pointerRows(gutterFrame(arrowRow = -1, discRow = 1)).len == 0
    check pointerRows(gutterFrame(arrowRow = -1, discRow = -1)).len == 0

proc columnFrame(bands: openArray[(int, int)]): GrayImage =
  ## One pane column, 200x300, bordered by gutters left and right; `bands`
  ## paints whole rows across it.
  result = blank(200, 300)
  result.rect(0, 4, 0, 300, Gutter)
  result.rect(196, 200, 0, 300, Gutter)
  for (y, gray) in bands: result.rect(0, 200, y, y + 1, gray)

proc splits(img: GrayImage; gutterTone: int): seq[GutterRun] =
  splitRect(img, Rect(x: 0, y: 0, w: 200, h: 300), vertical = false,
            minGutter = MinInteriorRowGutter, gutterTone = gutterTone)

suite "PLAT-42 window reader: a sticky-scroll shadow is not a splitter":
  const
    PushedShadow = [(75, 31), (76, 21), (77, 31), (78, 37)]
      ## `leaves.nim`'s 0.225/0.475/0.225/0.075 black over the ground.
    WholeShadow = [(75, 2), (76, 12), (77, 27), (78, 37), (79, 39)]
      ## 0.95/0.7/0.325/0.075/0.025, under whole headers.
    Splitter = [(150, 27), (151, 27), (152, 27), (153, 27),
                (154, 27), (155, 27), (156, 27), (157, 27)]

  test "the window's splitter splits":
    check splits(columnFrame(Splitter), Gutter) ==
      @[GutterRun(first: 150, last: 157)]

  test "neither sticky shadow splits the editor":
    check splits(columnFrame(PushedShadow), Gutter).len == 0
    check splits(columnFrame(WholeShadow), Gutter).len == 0
    check splits(columnFrame(@PushedShadow & @Splitter), Gutter) ==
      @[GutterRun(first: 150, last: 157)]

  test "planted: without the gutter tone the shadow is taken for a splitter":
    # The rule as it was before the shadow check: what cut the editor into
    # its title strip and an untitled body on four of the eight frames.
    check splits(columnFrame(PushedShadow), -1).len == 1

  test "a splitter blended toward the ground by a downscale still splits":
    # Lanczos only lightens a splitter's edges; nothing in one is darker
    # than the gutter.
    check splits(columnFrame([(150, 31), (151, 27), (152, 27), (153, 31)]),
                 Gutter).len == 1
