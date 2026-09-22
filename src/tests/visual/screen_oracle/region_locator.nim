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
## HOW THE GRID IS FOUND, AND WHY THIS METHOD RATHER THAN `detectWindowRects`
## ===========================================================================
##
## Measured 2026-09-22 over the pinned corpus. The CodeTracer layout draws
## inter-pane gutters in a darker tone than pane interiors, and the separation
## is not marginal — taking the MEDIAN of each column down the frame yields
## essentially two values:
##
##     column-median histogram, stepped-editor (1920x1080):
##         40 -> 1895 columns     (pane interior)
##         27 ->   24 columns     (gutter)
##         53 ->    1 column
##
## So a gutter is found by thresholding the column median, and the pane grid is
## the complement. The MEDIAN is what makes this work: a gutter column still
## passes through pane content at some rows, so a mean or a variance test is
## pulled off the gutter value by that content, while a median is not. An
## earlier attempt using low column VARIANCE found only three of the six
## gutters for exactly that reason.
##
## The method holds across both declared viewports, which is the property that
## matters, since `scenarios.json` declares `expectedViewports: 2` and three of
## the six frames are 1440x900 rather than 1920x1080:
##
##     1920x1080: vertical gutters at 0, 290, 769, 1163, 1556, 1916
##     1440x900 : vertical gutters at 0, 218, 577,  872, 1166, 1436
##
## Same structure — five pane columns, two pane rows — at different
## coordinates. **No coordinate in this module is a constant.**
##
## `vision_windows.detectWindowRects` is NOT used here, and the reason is its
## own documented limit rather than a preference: its header warns that it
## assumes light-on-dark chrome and *"may treat a full-bleed single window as
## background"*, which is precisely this frame — one window filling the screen,
## subdivided. `ocr.detectElements` is not used either, and that reason is
## measured rather than assumed: its only non-trivial backend, `ebOmniParser`,
## ALWAYS raises `OcrBackendUnavailable` because no weights are bundled. The
## reader says so by name rather than returning empty.

import std/[algorithm, sequtils, strutils, tables]
import gui_assert/image_math
import ./screen_reading

type
  Rect* = object
    x*, y*, w*, h*: int

  GutterRun* = object
    first*, last*: int

  PaneGrid* = object
    ## The located grid. `cells` is row-major over (rowBands x colBands).
    colBands*: seq[GutterRun]   ## the pane columns (between vertical gutters)
    rowBands*: seq[GutterRun]   ## the pane rows (between horizontal gutters)
    cells*: seq[Rect]

const
  GutterMedianThreshold* = 33
    ## **Derived, with its rejected values visible (§36b).**
    ##
    ## Measured gutter median is 27 and pane-interior median is 40, in both
    ## viewports, on every frame of the pinned corpus. The midpoint is 33.5.
    ##
    ## | candidate | result on the corpus | why not chosen |
    ## |---|---|---|
    ## | 28 | finds all gutters | only 1 above the gutter value; a slightly lighter gutter tone merges the whole frame into one cell |
    ## | **33** | **all 6 gutters in both viewports, 6 of margin either way** | **chosen — the midpoint, rounded down** |
    ## | 39 | finds all gutters | only 1 below the pane value; any pane drawn marginally darker becomes a gutter and the grid shatters |
    ## | 45 | **wrong** | pane interiors classify as gutters |
    ##
    ## Lowerable with a measurement; not raisable twice — the ratchet rule.

  MinGutterWidth* = 3
    ## A gutter is at least this many pixels wide. Measured: every gutter in the
    ## corpus is 4 px. Set to 3 rather than 4 so a one-pixel rendering
    ## difference does not lose a gutter, and not to 1 because a single dark
    ## column occurs inside content (a box border) and would split a pane.

  MinPaneExtent* = 24
    ## A band narrower than this is not a pane. Guards against a pair of
    ## adjacent gutters producing a sliver band.

  TitleStripHeight* = 30
    ## The top strip of a pane cell that carries its title/tab row. OCR'd on
    ## its own to identify the cell, because OCRing the whole cell returns the
    ## pane's CONTENT as well and the first line is not reliably the title.

  MinInteriorRowGutter* = 6
    ## **A pane's horizontal split is 8 px; everything thinner is furniture.**
    ##
    ## This constant exists because the grid is NOT a clean 2-D grid and a
    ## naive one is wrong: the editor column runs the full height of the frame
    ## while the three columns to its right are each split in two. A GLOBAL row
    ## scan sees the right-hand split and cuts the editor in half with it, so
    ## the rows are segmented PER COLUMN BAND instead.
    ##
    ## Within a band, interior dark runs are of two kinds, and they are cleanly
    ## separated — measured over all six pinned frames, interior runs only
    ## (frame chrome and status bar excluded):
    ##
    ## | scenario | interior run widths |
    ## |---|---|
    ## | stepped-editor | 1, 1, 3, 4, **8, 8, 8** |
    ## | advanced-state | 2, 3, 3, 4, **8, 8, 8** |
    ## | entry-shell | 1, 1, 4, **8, 8, 8** |
    ## | breakpoint-editor | 2, 3, 3, 4, **8, 8, 8** |
    ## | returned-calltrace | 2, 3, 3, 4, **8, 8, 8** |
    ## | continued-event-log | 1, 1, 2, 3, 3, 4, **8, 8, 8** |
    ##
    ## Every real pane split is 8 and every piece of furniture — a tab strip's
    ## underline, a search box's border — is at most 4. Three 8s per frame, in
    ## all six, which is the three right-hand column bands. A threshold of 6
    ## sits between the two populations with 2 px of margin below and 4 above.
    ##
    ## Rejected: 4 would promote the search-box border into a pane split and
    ## shatter the calltrace pane; 9 would find no splits at all and merge each
    ## right-hand column into one pane.

  GutterDarkFraction* = 0.95
    ## A line counts as a gutter when at least this fraction of it, inside the
    ## rect being split, is gutter-dark. See `darkFractionIn` for the measured
    ## defect that rules out a median.
    ##
    ## | candidate | effect on the corpus | why not chosen |
    ## |---|---|---|
    ## | 0.50 (a median) | **wrong** | splits the event log at x=1163 on a nine-row margin; rows truncate mid-text |
    ## | 0.80 | wrong | a gutter interrupted by one pane's content for a fifth of its length still passes |
    ## | **0.95** | **all real gutters found, no false ones** | **chosen** |
    ## | 1.00 | brittle | a single antialiased pixel anywhere along a true gutter rejects it |

  EdgeChromeMargin* = 60
    ## Runs closer than this to the top or bottom of the frame are the window
    ## chrome and the status bar, not pane splits. They are excluded before the
    ## width rule is applied — otherwise the 32-px status bar would be the
    ## widest "split" in every frame and would win every comparison.

func medianOf(values: var seq[uint8]): int =
  if values.len == 0: return 0
  values.sort()
  int(values[values.len div 2])

proc deriveGutterThreshold*(img: GrayImage): int =
  ## **THE THRESHOLD IS DERIVED FROM THE FRAME, NOT BAKED IN — because the two
  ## front-ends do not share a palette.**
  ##
  ## Measured 2026-09-22, column-median histograms of the same scenario:
  ##
  ##     Electron : pane 40 (1895 columns), gutter 27 (24 columns)
  ##     GPUI     : pane 33 (1380 columns), gutter 21 (540 columns)
  ##
  ## A fixed threshold of 33 — the midpoint of the ELECTRON pair — classifies
  ## the GPUI frame correctly only by luck: GPUI's pane median is *exactly* 33,
  ## so the margin is ZERO and a pane drawn one shade darker would be read as a
  ## gutter and shatter the layout. That is precisely the stated risk that a
  ## constant tuned on one fixture generalises to nothing, and a cross-renderer
  ## oracle whose geometry only works on one renderer would be worth very
  ## little.
  ##
  ## So the two populations are found in each frame and the threshold is placed
  ## between them. The histogram is strongly bimodal in both renderers, which
  ## is what makes this reliable rather than clever: the darkest common median
  ## is the gutter tone, the most common is the pane tone.
  ##
  ## `GutterMedianThreshold` remains as the FALLBACK for a frame with no
  ## discernible second population — and for a blank frame that is the right
  ## answer, because `isDegenerate` will reject it first anyway.
  var hist = initCountTable[int]()
  let yStart = min(90, img.height div 8)
  let yEnd = max(yStart + 1, img.height - max(70, img.height div 12))
  for x in 0 ..< img.width:
    var vals: seq[uint8] = @[]
    var y = yStart
    while y < yEnd:
      vals.add uint8(img.pixels[y * img.width + x])
      y += 3
    hist.inc medianOf(vals)
  if hist.len < 2: return GutterMedianThreshold
  # The pane tone is the most common median. The gutter tone is the most common
  # median BELOW it — "below" because a gutter is darker than a pane in both
  # renderers, and taking simply the second-most-common would pick up a
  # highlight band instead.
  let paneTone = hist.largest.key
  var gutterTone = -1
  var gutterCount = 0
  for tone, count in hist:
    if tone < paneTone and count > gutterCount:
      gutterTone = tone
      gutterCount = count
  if gutterTone < 0: return GutterMedianThreshold
  (paneTone + gutterTone) div 2

proc darkFractionIn*(img: GrayImage, r: Rect, vertical: bool,
                     index: int,
                     threshold = GutterMedianThreshold): float =
  ## The FRACTION of one line (column if `vertical`, else row) that is gutter-
  ## dark, measured inside `r` only.
  ##
  ## **A FRACTION AND NOT A MEDIAN, AND THE DIFFERENCE IS NOT COSMETIC.** A
  ## median asks "is this line dark more often than not", which is the wrong
  ## question for a line that is a gutter in part of the frame and pane
  ## elsewhere. Measured 2026-09-22 on `stepped-editor`: x=1163 is gutter-dark
  ## (27) for y in 38..546 and pane-light (40) for y in 547..1047 — 509 rows
  ## against 501. The median of the whole column is therefore 27 and the column
  ## is declared a full-height gutter on a nine-row margin, splitting the event
  ## log pane in half. The event log's own rows span x 785..1569, straight
  ## across that supposed gutter, so every row was truncated mid-text and the
  ## grammar correctly reported a mismatch on content that was really there.
  ##
  ## The fraction asks the right question: **is this line dark along
  ## essentially all of its extent.** At x=1163 over the full content rect it
  ## is ~0.50 and rejects; over the top half alone it is ~1.0 and accepts,
  ## which is exactly the structure the recursion needs.
  var dark = 0
  var total = 0
  if vertical:
    var y = r.y
    while y < r.y + r.h:
      if int(uint8(img.pixels[y * img.width + index])) < threshold:
        inc dark
      inc total
      y += 2
  else:
    var x = r.x
    while x < r.x + r.w:
      if int(uint8(img.pixels[index * img.width + x])) < threshold:
        inc dark
      inc total
      x += 2
  if total == 0: 0.0 else: dark / total

proc splitRect*(img: GrayImage, r: Rect, vertical: bool,
                minGutter: int,
                threshold = GutterMedianThreshold): seq[GutterRun] =
  ## Gutters inside `r`, measured inside `r` only.
  let n = if vertical: r.w else: r.h
  let origin = if vertical: r.x else: r.y
  var frac = newSeq[float](n)
  for i in 0 ..< n:
    frac[i] = darkFractionIn(img, r, vertical, origin + i, threshold)
  var i = 0
  while i < n:
    if frac[i] >= GutterDarkFraction:
      var j = i
      while j < n and frac[j] >= GutterDarkFraction: inc j
      # Edge-touching runs are the rect's own border, not an interior split.
      if j - i >= minGutter and i > 0 and j < n:
        result.add GutterRun(first: origin + i, last: origin + j - 1)
      i = j
    else:
      inc i

proc partition*(img: GrayImage, r: Rect, depth = 0,
                threshold = GutterMedianThreshold): seq[Rect] =
  ## **RECURSIVE BINARY PARTITION, BECAUSE THE LAYOUT IS NOT A GRID.**
  ##
  ## Measured 2026-09-22, and this is why a grid is wrong: in the 1920x1080
  ## frames a vertical gutter exists at x=1163 in the TOP half of the frame,
  ## separating the state pane from the calltrace pane — and does NOT exist in
  ## the bottom half, where `EVENT LOG`, `TIMELINE` and `TERMINAL OUTPUT` are
  ## TABS OF ONE PANE spanning x 773..1555. A global column scan applies the
  ## top half's gutter to the bottom half and cuts the event log in two, which
  ## truncates every row mid-text: `stdout: checksum = 73` was read as
  ## `stdout:` and the grammar then correctly reported a mismatch.
  ##
  ## The same asymmetry holds in the other axis — the editor column is full
  ## height while the columns right of it are split — so neither axis can be
  ## treated as global. Splitting recursively, measuring only inside the rect
  ## being split, is the shape that handles both.
  if depth > 6 or r.w < MinPaneExtent or r.h < MinPaneExtent:
    return @[r]
  # Try vertical first, then horizontal. Order does not matter for the result
  # because a rect with no split in one axis simply recurses on the other.
  let vg = splitRect(img, r, vertical = true, minGutter = MinGutterWidth,
                     threshold = threshold)
  if vg.len > 0:
    var cursor = r.x
    for g in vg:
      if g.first - cursor >= MinPaneExtent:
        result.add partition(img, Rect(x: cursor, y: r.y,
                                       w: g.first - cursor, h: r.h), depth + 1, threshold)
      cursor = g.last + 1
    if r.x + r.w - cursor >= MinPaneExtent:
      result.add partition(img, Rect(x: cursor, y: r.y,
                                     w: r.x + r.w - cursor, h: r.h), depth + 1, threshold)
    return
  let hg = splitRect(img, r, vertical = false,
                     minGutter = MinInteriorRowGutter, threshold = threshold)
  if hg.len > 0:
    var cursor = r.y
    for g in hg:
      if g.first - cursor >= MinPaneExtent:
        result.add partition(img, Rect(x: r.x, y: cursor,
                                       w: r.w, h: g.first - cursor), depth + 1, threshold)
      cursor = g.last + 1
    if r.y + r.h - cursor >= MinPaneExtent:
      result.add partition(img, Rect(x: r.x, y: cursor,
                                     w: r.w, h: r.y + r.h - cursor), depth + 1, threshold)
    return
  @[r]

proc columnMedians*(img: GrayImage): seq[int] =
  ## Median of each column, sampled down the frame. Sampling rather than every
  ## row because the median is stable under it and the cost is linear in the
  ## sample count; the stride is chosen so that even the shortest frame
  ## contributes hundreds of samples.
  result = newSeq[int](img.width)
  let yStart = min(90, img.height div 8)
  let yEnd = max(yStart + 1, img.height - max(70, img.height div 12))
  for x in 0 ..< img.width:
    var vals: seq[uint8] = @[]
    var y = yStart
    while y < yEnd:
      vals.add uint8(img.pixels[y * img.width + x])
      y += 3
    result[x] = medianOf(vals)

proc rowMedians*(img: GrayImage, xFrom = -1, xTo = -1): seq[int] =
  ## Median of each row. When `xFrom`/`xTo` are given the median is taken over
  ## that column band ONLY, which is what makes per-band row segmentation
  ## possible — see `MinInteriorRowGutter` for why a global row scan is wrong.
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
    result[y] = medianOf(vals)

func interiorGutters*(gutters: openArray[GutterRun], height: int,
                      margin = EdgeChromeMargin,
                      minWidth = MinInteriorRowGutter): seq[GutterRun] =
  ## Interior runs wide enough to be a pane split. Chrome and status bar are
  ## dropped BEFORE the width rule, because the status bar is wider than any
  ## real split and would otherwise dominate.
  for g in gutters:
    if g.first > margin and g.last < height - margin and
       g.last - g.first + 1 >= minWidth:
      result.add g

func gutterRuns*(medians: openArray[int],
                 threshold = GutterMedianThreshold,
                 minWidth = MinGutterWidth): seq[GutterRun] =
  ## Contiguous runs whose median is below the threshold.
  var i = 0
  while i < medians.len:
    if medians[i] < threshold:
      var j = i
      while j < medians.len and medians[j] < threshold: inc j
      if j - i >= minWidth:
        result.add GutterRun(first: i, last: j - 1)
      i = j
    else:
      inc i

func bandsBetween*(gutters: openArray[GutterRun], extent: int): seq[GutterRun] =
  ## The complement of the gutters: the bands a pane can occupy.
  var cursor = 0
  for g in gutters:
    if g.first - cursor >= MinPaneExtent:
      result.add GutterRun(first: cursor, last: g.first - 1)
    cursor = g.last + 1
  if extent - cursor >= MinPaneExtent:
    result.add GutterRun(first: cursor, last: extent - 1)

func isDegenerate*(medians: openArray[int],
                   threshold = GutterMedianThreshold): bool =
  ## **The blank-frame test, and it is NOT "no rectangles were found".**
  ##
  ## A uniform image has no between-class variance, which is the documented
  ## degeneracy of Otsu on a unimodal histogram. Here the equivalent statement
  ## is that every column median is the SAME value — whether that value is
  ## above or below the threshold. Both arms matter: an all-dark frame makes
  ## the whole width one "gutter" and an all-light frame makes it one band, and
  ## a test that only checked one of those would call the other one a pane.
  ##
  ## This is what makes `LAW-R3` hold: a blank frame is `urFrameBlank`, never
  ## `srEmpty`.
  if medians.len == 0: return true
  let first = medians[0]
  medians.allIt(it == first)

proc locateGrid*(img: GrayImage): ScreenReading[PaneGrid] =
  ## Locate the pane grid, or say why not.
  if img.width == 0 or img.height == 0:
    return unreadable[PaneGrid](urFrameBlank, "image has a zero dimension")
  let threshold = deriveGutterThreshold(img)
  let cm = columnMedians(img)
  let rm = rowMedians(img)
  if isDegenerate(cm) or isDegenerate(rm):
    return unreadable[PaneGrid](urFrameBlank,
      "every column or row median is identical: the frame carries no layout")
  let colGutters = gutterRuns(cm, threshold)
  let colBands = bandsBetween(colGutters, img.width)
  # The frame's own top/bottom chrome, taken once from the full-width scan, so
  # every band starts below the toolbar and ends above the status bar.
  let frameRowGutters = gutterRuns(rm, threshold)
  var contentTop = 0
  var contentBottom = img.height - 1
  # **THE CHROME IS FOUND BY ZONE, NOT BY TOUCHING THE FRAME EDGE.**
  #
  # An earlier version took the run whose `last` equalled `height - 1`. That is
  # right on 1920x1080, where the status bar is one run reaching the last row,
  # and WRONG on 1440x900, where the bottom chrome is two runs — (868,881) and
  # (889,899) — separated by a lighter band. Only the second touches the edge,
  # so the content area was left ending at 888 and carried 20 rows of status
  # bar into the bottom panes. The event log's footer line then OCR'd fused
  # with `... certificates /home/...` from the status bar and stopped matching
  # its own grammar. Taking the FIRST run that begins inside the bottom zone
  # handles both layouts.
  let topZone = img.height div 6
  let bottomZone = img.height - img.height div 6
  for g in frameRowGutters:
    if g.first <= topZone and g.last + 1 > contentTop:
      contentTop = g.last + 1
  for g in frameRowGutters:
    if g.first >= bottomZone:
      contentBottom = g.first - 1
      break
  if colBands.len == 0 or contentBottom <= contentTop:
    return unreadable[PaneGrid](urFrameBlank,
      "thresholding produced no pane bands (cols=" & $colBands.len & ")")

  var grid = PaneGrid(colBands: colBands,
                      rowBands: @[GutterRun(first: contentTop,
                                            last: contentBottom)])
  # The content area, with the window chrome and status bar removed, is
  # partitioned RECURSIVELY — see `partition` for the measurement that rules
  # out a grid.
  grid.cells = partition(img, Rect(x: 0, y: contentTop, w: img.width,
                                   h: contentBottom - contentTop + 1),
                         0, threshold)
  if grid.cells.len == 0:
    return unreadable[PaneGrid](urFrameBlank, "no pane cells survived segmentation")
  read(grid)

func titleStrip*(cell: Rect): Rect =
  ## The top strip of a cell, where its title/tab row is drawn.
  Rect(x: cell.x, y: cell.y, w: cell.w, h: min(TitleStripHeight, cell.h))

func bodyBelowTitle*(cell: Rect): Rect =
  let skip = min(TitleStripHeight, cell.h)
  Rect(x: cell.x, y: cell.y + skip, w: cell.w, h: cell.h - skip)

func `$`*(r: Rect): string =
  "(" & $r.x & "," & $r.y & " " & $r.w & "x" & $r.h & ")"
