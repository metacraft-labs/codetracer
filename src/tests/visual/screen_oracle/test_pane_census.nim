## Pixel-level regression for the five-pane desktop census. These constructed
## rasters isolate the measured splitter geometry from OCR and live-window
## availability: they are inputs to the real locator (`paneCells` is
## GuiAssert's `subdivideRect` with this layout's rules, and `locateGrid` is
## GuiAssert's `detectWindowRects`), not a mocked locator.
## The live capture lane additionally checks the complete product frame.
import std/[strutils, unittest]
import gui_assert/image_math
import ./region_locator
import ./vision_producer
import ./screen_reading

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
    let cells = paneCells(img, Rect(x: 0, y: 38, w: 1920, h: 1010))
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
    check paneCells(img, Rect(x: 0, y: 38, w: 1440, h: 830)) == @[
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
      check paneCells(img, Rect(x: 0, y: 0, w: 600, h: 500)).len == 1

  test "a border reaching only one side is still furniture":
    for thickness in 3 .. 4:
      for inset in [Rect(x: 0, y: 100, w: 599, h: thickness),
                    Rect(x: 1, y: 100, w: 599, h: thickness)]:
        var img = ground(600, 500)
        img.paint(inset)
        check paneCells(img, Rect(x: 0, y: 0, w: 600, h: 500)).len == 1

  test "one- and two-pixel full-width rules remain furniture":
    # Three dark rows are a real laptop splitter, measured above; treating
    # them as furniture would reinstate the defect for half the corpus.
    for thickness in 1 .. 2:
      var img = ground(600, 500)
      img.paint(Rect(x: 0, y: 100, w: 600, h: thickness))
      check paneCells(img, Rect(x: 0, y: 0, w: 600, h: 500)).len == 1

  test "a four-pixel splitter accepts the measured one-level tone variation":
    var img = ground(600, 500)
    img.paint(Rect(x: 0, y: 246, w: 600, h: 4))
    img.paint(Rect(x: 0, y: 247, w: 600, h: 1), tone = 28)
    check paneCells(img, Rect(x: 0, y: 0, w: 600, h: 500)) == @[
      Rect(x: 0, y: 0, w: 600, h: 246),
      Rect(x: 0, y: 250, w: 600, h: 250)]

  test "interrupted endpoint pixels do not manufacture a continuous splitter":
    var img = ground(600, 500)
    img.paint(Rect(x: 0, y: 246, w: 600, h: 8))
    # The interior is dark throughout, and each end has seven dark rows, but
    # no common run reaches the three-row splitter floor.
    img.paint(Rect(x: 0, y: 248, w: 1, h: 1), tone = 40)
    img.paint(Rect(x: 599, y: 251, w: 1, h: 1), tone = 40)
    check paneCells(img, Rect(x: 0, y: 0, w: 600, h: 500)).len == 1

  test "a splitter core survives dark rounded-corner extensions":
    var img = ground(600, 500)
    img.paint(Rect(x: 8, y: 244, w: 584, h: 8))
    img.paint(Rect(x: 0, y: 246, w: 600, h: 4))
    check paneCells(img, Rect(x: 0, y: 0, w: 600, h: 500)) == @[
      Rect(x: 0, y: 0, w: 600, h: 244),
      Rect(x: 0, y: 252, w: 600, h: 248)]

  test "eight-pixel historical splitter remains a pane boundary":
    var img = ground(600, 500)
    img.paint(Rect(x: 0, y: 246, w: 600, h: 8))
    check paneCells(img, Rect(x: 0, y: 0, w: 600, h: 500)) == @[
      Rect(x: 0, y: 0, w: 600, h: 246),
      Rect(x: 0, y: 254, w: 600, h: 246)]

  test "the whole frame is located through the window detector, full-bleed":
    # One window over the whole frame: the tool bar row joins every pane into
    # one component, which `detectWindowRects` used to drop as background.
    var img = ground(1920, 1080)
    img.paint(Rect(x: 0, y: 34, w: 1920, h: 4))       # under the tool bar
    img.paint(Rect(x: 0, y: 1048, w: 1920, h: 4))     # over the status bar
    img.paint(Rect(x: 385, y: 38, w: 4, h: 1010))
    img.paint(Rect(x: 865, y: 38, w: 4, h: 1010))
    img.paint(Rect(x: 869, y: 539, w: 1051, h: 4))
    img.paint(Rect(x: 1391, y: 38, w: 4, h: 501))
    let grid = locateGrid(img)
    check grid.isRead
    check grid.value.cells == @[
      Rect(x: 0, y: 38, w: 385, h: 1010),
      Rect(x: 389, y: 38, w: 476, h: 1010),
      Rect(x: 869, y: 38, w: 522, h: 501),
      Rect(x: 1395, y: 38, w: 525, h: 501),
      Rect(x: 869, y: 543, w: 1051, h: 505)]

  test "the separator threshold is taken from the frame, per palette":
    # Electron's ground 40 / gutter 27 and GPUI's ground 33 / gutter 21: a
    # constant between one pair has no margin on the other.
    for (groundTone, gutterTone) in [(40, 27), (33, 21)]:
      var img = GrayImage(width: 600, height: 400,
                          pixels: repeat(char(groundTone), 600 * 400))
      img.paint(Rect(x: 296, y: 0, w: 4, h: 400), gutterTone)
      let t = locatorThresholds(img)
      check t.separatorTone == gutterTone
      check t.threshold > gutterTone
      check t.threshold < groundTone
      check paneCells(img, Rect(x: 0, y: 0, w: 600, h: 400),
                      t.threshold, t.separatorTone).len == 2

  test "a blank frame is degenerate in both arms, a structured one is not":
    check isDegenerate(GrayImage(width: 300, height: 200,
                                 pixels: repeat(char(0), 300 * 200)))
    check isDegenerate(GrayImage(width: 300, height: 200,
                                 pixels: repeat(char(255), 300 * 200)))
    var img = ground(300, 200)
    img.paint(Rect(x: 148, y: 0, w: 4, h: 200))
    check not isDegenerate(img)
