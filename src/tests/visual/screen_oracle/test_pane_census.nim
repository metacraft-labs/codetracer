## Pixel-level regression for the five-pane desktop census. These constructed
## rasters isolate the measured splitter geometry from OCR and live-window
## availability: they are inputs to the real locator, not a mocked locator.
## The live capture lane additionally checks the complete product frame.
import std/[strutils, unittest]
import gui_assert/image_math
import ./region_locator
import ./vision_producer

proc ground(w, h: int): GrayImage =
  GrayImage(width: w, height: h, pixels: repeat(char(40), w * h))

proc paint(img: var GrayImage, r: Rect, tone = 27) =
  for y in r.y ..< r.y + r.h:
    for x in r.x ..< r.x + r.w:
      img.pixels[y * img.width + x] = char(tone)

suite "desktop pane census":
  test "four-pixel horizontal split exposes Variables and Calltrace above Event Log":
    var img = ground(1920, 1080)
    img.paint(Rect(x: 385, y: 38, w: 4, h: 1010))
    img.paint(Rect(x: 865, y: 38, w: 4, h: 1010))
    img.paint(Rect(x: 869, y: 539, w: 1051, h: 4))
    img.paint(Rect(x: 1391, y: 38, w: 4, h: 501))
    let cells = partition(img, Rect(x: 0, y: 38, w: 1920, h: 1010))
    check cells == @[
      Rect(x: 0, y: 38, w: 385, h: 1010),
      Rect(x: 389, y: 38, w: 476, h: 1010),
      Rect(x: 869, y: 38, w: 522, h: 501),
      Rect(x: 1395, y: 38, w: 525, h: 501),
      Rect(x: 869, y: 543, w: 1051, h: 505)]

  test "Variables and State both identify the program-state pane":
    check classifyTitle("Variables") == piProgramState
    check classifyTitle("VARIABLES") == piProgramState
    check classifyTitle("State") == piProgramState
    check classifyTitle("Constraints") == piOther

  test "the laptop's three dark rows still expose all five panes":
    # Measured on the 1440x900 settled product raster after the capture
    # lane's Lanczos reduction to points. The nominal 4px splitter contributes
    # three gutter-dark rows; width alone must not merge the right column.
    var img = ground(1440, 900)
    img.paint(Rect(x: 289, y: 38, w: 4, h: 830))
    img.paint(Rect(x: 650, y: 38, w: 3, h: 830))
    img.paint(Rect(x: 653, y: 450, w: 787, h: 3))
    img.paint(Rect(x: 1043, y: 38, w: 4, h: 412))
    check partition(img, Rect(x: 0, y: 38, w: 1440, h: 830)) == @[
      Rect(x: 0, y: 38, w: 289, h: 830),
      Rect(x: 293, y: 38, w: 357, h: 830),
      Rect(x: 653, y: 38, w: 390, h: 412),
      Rect(x: 1047, y: 38, w: 393, h: 412),
      Rect(x: 653, y: 453, w: 787, h: 415)]

  test "inset three- and four-pixel search-box borders do not split a pane":
    for thickness in 3 .. 4:
      var img = ground(600, 500)
      img.paint(Rect(x: 8, y: 100, w: 584, h: thickness))
      img.paint(Rect(x: 8, y: 140, w: 584, h: thickness))
      check partition(img, Rect(x: 0, y: 0, w: 600, h: 500)).len == 1

  test "a border reaching only one side is still furniture":
    for thickness in 3 .. 4:
      for inset in [Rect(x: 0, y: 100, w: 599, h: thickness),
                    Rect(x: 1, y: 100, w: 599, h: thickness)]:
        var img = ground(600, 500)
        img.paint(inset)
        check partition(img, Rect(x: 0, y: 0, w: 600, h: 500)).len == 1

  test "one- and two-pixel full-width rules remain furniture":
    # Three dark rows are a real laptop splitter, measured above; treating
    # them as furniture would reinstate the defect for half the corpus.
    for thickness in 1 .. 2:
      var img = ground(600, 500)
      img.paint(Rect(x: 0, y: 100, w: 600, h: thickness))
      check partition(img, Rect(x: 0, y: 0, w: 600, h: 500)).len == 1

  test "a four-pixel splitter accepts the measured one-level tone variation":
    var img = ground(600, 500)
    img.paint(Rect(x: 0, y: 246, w: 600, h: 4))
    img.paint(Rect(x: 0, y: 247, w: 600, h: 1), tone = 28)
    check partition(img, Rect(x: 0, y: 0, w: 600, h: 500)) == @[
      Rect(x: 0, y: 0, w: 600, h: 246),
      Rect(x: 0, y: 250, w: 600, h: 250)]

  test "interrupted endpoint pixels do not manufacture a continuous splitter":
    var img = ground(600, 500)
    img.paint(Rect(x: 0, y: 246, w: 600, h: 8))
    # The interior is dark throughout, and each end has seven dark rows, but
    # no common run reaches the three-row splitter floor.
    img.paint(Rect(x: 0, y: 248, w: 1, h: 1), tone = 40)
    img.paint(Rect(x: 599, y: 251, w: 1, h: 1), tone = 40)
    check partition(img, Rect(x: 0, y: 0, w: 600, h: 500)).len == 1

  test "a splitter core survives dark rounded-corner extensions":
    var img = ground(600, 500)
    img.paint(Rect(x: 8, y: 244, w: 584, h: 8))
    img.paint(Rect(x: 0, y: 246, w: 600, h: 4))
    check partition(img, Rect(x: 0, y: 0, w: 600, h: 500)) == @[
      Rect(x: 0, y: 0, w: 600, h: 244),
      Rect(x: 0, y: 252, w: 600, h: 248)]

  test "eight-pixel historical splitter remains a pane boundary":
    var img = ground(600, 500)
    img.paint(Rect(x: 0, y: 246, w: 600, h: 8))
    check partition(img, Rect(x: 0, y: 0, w: 600, h: 500)) == @[
      Rect(x: 0, y: 0, w: 600, h: 246),
      Rect(x: 0, y: 254, w: 600, h: 246)]
