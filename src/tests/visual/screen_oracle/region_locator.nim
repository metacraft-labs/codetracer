## PLAT-39 — locating panes in a frame, from the pixels alone.
##
## **NOTHING HERE READS THE APPLICATION.** No selector, no attribute, no
## `pane-rectangles` answer. The published rectangles exist in
## `src/tests/visual/answers/*.electron.json` and using them would make this
## module a second reader of the DOM producer's output, which is exactly the
## §30a shape the milestone exists to avoid: a differential whose two sides
## share a source measures nothing.
##
## ===========================================================================
## HOW THE PANES ARE FOUND: GuiAssert's window detector, on a full-bleed window
## ===========================================================================
##
## The CodeTracer layout draws inter-pane separators (gutters and splitters)
## in a darker tone than the pane interiors. Both front-ends fill the screen
## with ONE window subdivided into panes, which is the case GuiAssert's
## `detectWindowRects` used to throw away as background (a component covering
## more than 98% of the frame). It now subdivides such a component along its
## interior separators (`subdivideRect`) and returns the panes, so this module
## is a thin layer over it:
##
##   1. `separatorTones` takes the frame's ground (its histogram's mode) and the
##      most frequent darker tone (the separators), and the threshold between
##      them. Measured palettes: Electron ground 40 / gutter 27, GPUI ground 33
##      / gutter 21 — the two front-ends do not share one, which is why the
##      threshold is taken per frame and never baked in. Otsu would split the
##      text from the ground instead, and leave every pane and gutter in one
##      class.
##   2. `detectWindowRects` with that threshold finds the window and its panes;
##      the status bar and tool bars are thinner than `maxAspect` allows and
##      drop out by shape.
##
## The separator rules the detector applies — a separator is dark along 95%
## of the rect being split, at least three lines thick, measured inside that
## rect only (the layout is not a grid: the editor column is full height while
## the columns to its right are split), a horizontal one connects both sides,
## and a run darker than the separator tone is a shadow — are the ones this
## module measured on the pinned corpus and used to implement itself. They
## moved into GuiAssert with the rest of the method.
##
## `ocr.detectElements` is not used, and that reason is measured rather than
## assumed: its only non-trivial backend, `ebOmniParser`, ALWAYS raises
## `OcrBackendUnavailable` because no weights are bundled. The reader says so by
## name rather than returning empty.

import std/algorithm
import gui_assert/image_math
import gui_assert/core/vision_windows
import ./screen_reading

type
  Rect* = object
    x*, y*, w*, h*: int

  GutterRun* = object
    first*, last*: int

  PaneGrid* = object
    ## The located panes, in reading order (top-to-bottom, then
    ## left-to-right).
    cells*: seq[Rect]

const
  FallbackSeparatorThreshold* = 33
    ## The threshold used when a frame has no darker population than its
    ## ground (`separatorTones` answers -1). Measured on the pinned corpus:
    ## gutter 27, pane 40, midpoint rounded down. A frame like that has no
    ## separators to find, so this only decides how it is refused.

  MinSeparatorLines* = 3
    ## The thinnest separator, in lines, in either axis.
    ##
    ## Historical measurement over all six pinned frames, interior runs only:
    ## real splits were 8 px (with a transparent header strip), furniture 1-4.
    ## Re-measured 2026-11-03 at 977b82e43 on the six settled Electron page
    ## rasters, reduced to points with the capture lane's Lanczos filter: wide
    ## frames have 4 gutter-dark rows (539..542), laptop frames have 3
    ## (450..452), and all connect both sides of their column; the laptop
    ## editor's inset furniture has a 3-row run at y=112 that reaches neither
    ## side. So width no longer separates the populations and the side rule
    ## does.
    ##
    ## | candidate | consequence | decision |
    ## |---|---|---|
    ## | 3, width only | promotes inset borders into pane splits | rejected |
    ## | 3, with side continuity | accepts both viewports and historical splitters, rejects inset furniture | chosen |
    ## | 4, with side continuity | accepts wide frames but merges every laptop right column | rejected |
    ## | 6 | merges the current right column into one cell | rejected |

  MinPaneExtent* = 24
    ## A band narrower than this is not a pane: a pair of adjacent separators
    ## would otherwise leave a sliver cell.

  SplitterDarkerSlack* = 3
    ## Grey levels a horizontal splitter's darkest row may sit BELOW the
    ## frame's separator tone and still be a splitter.
    ##
    ## A splitter is painted in the separator's colour, and a rasteriser or a
    ## downscale only blends it toward the LIGHTER ground beside it. A SHADOW
    ## is darker: since the editor learned Monaco's sticky scroll (2026-10-17),
    ## a scrolled GPUI editor draws the sticky widget's shadow across the whole
    ## pane under its headers (rows of 31, 21, 31, 37 over the 40 ground,
    ## measured on the `stepped-editor` window frame at codetracer
    ## `b7e12b7450b`), three rows under the threshold, reaching both sides.
    ##
    ## | candidate | consequence | decision |
    ## |---|---|---|
    ## | no check | the sticky shadow splits the editor | rejected (the defect) |
    ## | 0 | a one-level rounding difference drops a real splitter | rejected |
    ## | **3** | **splitters (27 at gutter 27) kept; the shadows' 21 rejected** | **chosen** |
    ## | 6 | the pushed-up shadow's 21 sits exactly 6 under 27 and splits again | rejected |

  MinPaneAreaPermille* = 15
    ## A located cell smaller than this share of the frame (per mille) is not
    ## a pane: `detectWindowRects`' own default floor (1.5%), applied after
    ## the shadow merge rather than before it.

  TitleStripHeight* = 30
    ## The top strip of a pane cell that carries its title/tab row. OCR'd on
    ## its own to identify the cell, because OCRing the whole cell returns the
    ## pane's CONTENT as well and the first line is not reliably the title.

  BlankShare* = 0.999
    ## A frame is blank when one grey level holds at least this share of its
    ## pixels. Real frames of either front-end hold their ground at well under
    ## 0.9 (text, chrome and separators are the rest); a uniform frame holds
    ## exactly 1.0.

func toArr(r: Rect): array[4, int] = [r.x, r.y, r.w, r.h]
func toRect(a: array[4, int]): Rect = Rect(x: a[0], y: a[1], w: a[2], h: a[3])

proc isDegenerate*(img: GrayImage): bool =
  ## **The blank-frame test, and it is NOT "no rectangles were found".**
  ##
  ## A uniform image has no between-class variance — the documented
  ## degeneracy of Otsu on a unimodal histogram. Both arms matter: an all-dark
  ## frame and an all-light frame are equally blank, and a test that checked
  ## only one would call the other one a pane. This is what makes `LAW-R3`
  ## hold: a blank frame is `urFrameBlank`, never `srEmpty`.
  let n = img.width * img.height
  if n <= 0 or img.pixels.len < n: return true
  var hist: array[256, int]
  for i in 0 ..< n: inc hist[ord(img.pixels[i])]
  var top = 0
  for c in hist: top = max(top, c)
  float(top) >= BlankShare * float(n)

proc locatorThresholds*(img: GrayImage): tuple[threshold, separatorTone: int] =
  ## The frame's separator threshold and tone (`separatorTones`), with the
  ## fallback when the frame has no darker population.
  let t = separatorTones(img)
  if t.threshold < 0: (FallbackSeparatorThreshold, -1) else: t

proc paneCells*(img: GrayImage, r: Rect,
                threshold = FallbackSeparatorThreshold,
                separatorTone = -1): seq[Rect] =
  ## `r` split into its panes along its interior separators — GuiAssert's
  ## `subdivideRect` with this layout's measured rules.
  let floor = if separatorTone >= 0: separatorTone - SplitterDarkerSlack else: -1
  for c in subdivideRect(img, r.toArr, threshold,
                         minSeparator = MinSeparatorLines,
                         minCell = MinPaneExtent, separatorFloor = floor):
    result.add c.toRect

proc rowSplits*(img: GrayImage, r: Rect,
                threshold = FallbackSeparatorThreshold,
                separatorTone = -1): seq[GutterRun] =
  ## The horizontal separators `paneCells` would split `r` at.
  let floor = if separatorTone >= 0: separatorTone - SplitterDarkerSlack else: -1
  for s in separatorsIn(img, r.toArr, vertical = false, threshold,
                        MinSeparatorLines, floor):
    result.add GutterRun(first: s.first, last: s.last)

proc locateGrid*(img: GrayImage): ScreenReading[PaneGrid] =
  ## Locate the panes, or say why not.
  if img.width == 0 or img.height == 0:
    return unreadable[PaneGrid](urFrameBlank, "image has a zero dimension")
  if isDegenerate(img):
    return unreadable[PaneGrid](urFrameBlank,
      "one grey level fills the frame: it carries no layout")
  let (threshold, tone) = locatorThresholds(img)
  # `minAreaFrac` low: a pane's title strip that a shadow parted from its
  # body is a small component, and it must survive to be merged back (below);
  # what is still too small after the merge is dropped there.
  let rects = detectWindowRects(img, threshold = threshold,
    minAreaFrac = 0.001, minSeparator = MinSeparatorLines,
    separatorFloor = (if tone >= 0: tone - SplitterDarkerSlack else: -1))
  if rects.len == 0:
    return unreadable[PaneGrid](urRegionNotLocated,
      "no window or pane rectangle survived detection (threshold " &
      $threshold & ")")
  var cells: seq[Rect] = @[]
  for r in rects: cells.add r.toRect
  # A COMPONENT BOUNDARY IS NOT ALWAYS A SEPARATOR. Where two located cells
  # share one column and are parted by a few dark rows, those rows may be a
  # SHADOW (GPUI's sticky-scroll shadow under the editor's headers: rows of
  # 2, 12, 27 over the 40 ground, measured on the `calltrace` window frame
  # 2026-11-21), which parts the foreground into two components although it
  # is no splitter. The two are merged unless the separator rules — the same
  # ones `paneCells` applies, shadow floor included — find a split in the gap.
  var merged = true
  while merged:
    merged = false
    block scan:
      for i in 0 ..< cells.len:
        for j in 0 ..< cells.len:
          let a = cells[i]
          let b = cells[j]
          if i == j or a.x != b.x or a.w != b.w: continue
          let gap = b.y - (a.y + a.h)
          if gap < 0 or gap > 8: continue
          let u = Rect(x: a.x, y: a.y, w: a.w, h: b.y + b.h - a.y)
          var split = false
          for g in rowSplits(img, u, threshold, tone):
            if g.first <= b.y - 1 and g.last >= a.y + a.h: split = true
          if not split:
            cells[i] = u
            cells.delete j
            merged = true
            break scan
  let frameArea = img.width * img.height
  var grid = PaneGrid()
  for c in cells:
    if c.w >= MinPaneExtent and c.h >= MinPaneExtent and
       c.w * c.h * 1000 >= MinPaneAreaPermille * frameArea:
      grid.cells.add c
  if grid.cells.len == 0:
    return unreadable[PaneGrid](urRegionNotLocated,
      "no located rectangle is large enough to be a pane")
  read(grid)

proc rowMedians*(img: GrayImage, xFrom = -1, xTo = -1): seq[int] =
  ## Median grey level of each row over the column band `xFrom..xTo` (the
  ## whole width, less a margin, when not given). Not a locator: the editor
  ## readers use it for a row's own background, against which the execution
  ## band and the ink of a text row stand out.
  result = newSeq[int](img.height)
  let lo = if xFrom >= 0: max(0, xFrom) else: min(10, img.width div 16)
  let hi = if xTo >= 0: min(img.width, xTo + 1)
           else: max(lo + 1, img.width - max(10, img.width div 16))
  for y in 0 ..< img.height:
    var vals: seq[uint8] = @[]
    var x = lo
    while x < hi:
      vals.add uint8(img.pixels[y * img.width + x])
      x += 3
    if vals.len > 0:
      vals.sort()
      result[y] = int(vals[vals.len div 2])

func titleStrip*(cell: Rect): Rect =
  ## The top strip of a cell, where its title/tab row is drawn.
  Rect(x: cell.x, y: cell.y, w: cell.w, h: min(TitleStripHeight, cell.h))

func bodyBelowTitle*(cell: Rect): Rect =
  let skip = min(TitleStripHeight, cell.h)
  Rect(x: cell.x, y: cell.y + skip, w: cell.w, h: cell.h - skip)

func `$`*(r: Rect): string =
  "(" & $r.x & "," & $r.y & " " & $r.w & "x" & $r.h & ")"
