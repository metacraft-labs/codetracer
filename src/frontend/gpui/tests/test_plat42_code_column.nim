## Controlled grayscale rasters isolate the producer's pixel predicate from
## OCR and GPU rasterization: the defect is whether folding ink is mistaken
## for the code boundary. These are synthetic images, not mocked readers;
## both controls call the same helper the real record producer calls.
## Lives in the executable GPUI lane, whose flags include GuiAssert: the
## screen-oracle inventory is recipe-owned and does not execute new suites.
import std/unittest
import gui_assert/image_math
import ../../../tests/visual/screen_oracle/[region_locator, plat42_code_column]

const Rows = [CodeColumnRow(y0: 0, y1: 24),
              CodeColumnRow(y0: 24, y1: 48, pointer: true),
              CodeColumnRow(y0: 48, y1: 72)]
const Pane = Rect(x: 0, y: 0, w: 300, h: 72)

proc rect(img: var GrayImage; x0, x1, y0, y1: int; gray: int) =
  for y in y0 ..< y1:
    for x in x0 ..< x1: img.pixels[y * img.width + x] = char(gray)

proc frame(code, fold: int): GrayImage =
  result = GrayImage(width: Pane.w, height: Pane.h,
                     pixels: newString(Pane.w * Pane.h))
  result.rect(0, Pane.w, 0, Pane.h, 40)
  result.rect(code, Pane.w - 2, 24, 48, 64)
  for row in Rows:
    result.rect(code, code + 4, row.y0 + 9, row.y0 + 14, 180)
    result.rect(fold, fold + 4, row.y0 + 7, row.y0 + 11, 180)

suite "PLAT-42 code-column pixel reader":
  test "old folding position is excluded by the original reader":
    check codeColumnLeft(frame(110, 84), Pane, 49, Rows) == 110

  test "folding ink cannot become the code-column boundary":
    check codeColumnLeft(frame(110, 100), Pane, 49, Rows) == 110

  test "the boundary follows the execution background, not a fixed offset":
    for code in [80, 110, 157, 190]:
      for fold in [60, code - 10, code - 5]:
        check codeColumnLeft(frame(code, fold), Pane, 49, Rows) == code

  test "a narrow full-height gutter strip is not the code band":
    var img = frame(157, 147)
    img.rect(55, 60, 24, 48, 64)
    check codeColumnLeft(img, Pane, 49, Rows) == 157

  test "the band boundary is visible even when the source row has no ink":
    var img = frame(157, 147)
    img.rect(157, Pane.w - 2, 24, 48, 64)
    check codeColumnLeft(img, Pane, 49, Rows) == 157

  test "no execution band is an unreadable boundary, not invented code":
    var img = frame(110, 100)
    img.rect(110, Pane.w - 2, 24, 48, 40)
    check codeColumnLeft(img, Pane, 49, Rows) == -1
    img.rect(0, Pane.w, 0, Pane.h, 40)
    check codeColumnLeft(img, Pane, 49, Rows) == -1

  test "missing or ambiguous execution pointers cannot identify a band":
    var rows = Rows
    rows[1].pointer = false
    check codeColumnLeft(frame(110, 100), Pane, 49, rows) == -1
    rows[0].pointer = true
    rows[1].pointer = true
    check codeColumnLeft(frame(110, 100), Pane, 49, rows) == -1
