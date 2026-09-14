## terminal_graphics/aspect.nim — PLAT-14 deliverable 3.
##
## §2.4: *"A terminal cell is roughly twice as tall as it is wide, and the
## exact ratio varies by font. An image drawn without correction is stretched
## vertically by 2. The renderer corrects using the cell aspect reported by the
## terminal (`CSI 16 t` where available, a configured default otherwise), and
## **the correction is visible in the model** so a test can assert it rather
## than a human noticing the picture looks wrong."*
##
## So the correction is a value on the rendering, not a fudge factor inside a
## loop. `CellAspect` is what `CSI 16 t` reports — the cell's size in device
## pixels — and `fitToCells` is the whole of the correction.
##
## ## THE CORRECTION IS INDEPENDENT OF THE TIER, AND THAT IS NOT OBVIOUS
##
## A tier changes how many SAMPLES a cell carries (1x2 for a half block, 2x4
## for braille), so the instinct is that the fit depends on it. It does not:
## the thing that must match the source's aspect is the DISPLAYED RECTANGLE,
## which is `cols * cellWidthPx` by `rows * cellHeightPx` whatever the tier
## packs inside each cell. A fit that folded the sub-cell geometry in would
## stretch braille by 2 relative to half blocks — two tiers of one image with
## different shapes, which §2.6's "a lower tier shows the same content at lower
## fidelity" forbids. `aspect_test.nim` asserts the fit is equal across the
## drawable tiers for exactly this reason.

import std/math

type
  CellAspect* = object
    ## One terminal cell's size in device pixels, as `CSI 16 t` reports it
    ## (`CSI 6 ; <height> ; <width> t`).
    widthPx*: int
    heightPx*: int
    source*: CellAspectSource

  CellAspectSource* = enum
    ## WHERE the ratio came from — carried for `TerminalCapabilities`' reason:
    ## "why is my picture squashed?" has to be answerable from the value rather
    ## than by re-deriving the decision from a terminal the reader cannot see.
    casDefault = "default"    ## nothing reported; `DefaultCellAspect` assumed
    casReported = "reported"  ## the terminal answered `CSI 16 t`
    casConfigured = "configured"  ## a user or a test pinned it

  CellFit* = object
    ## The corrected extent, plus everything needed to check it.
    cols*: int
    rows*: int
    aspect*: CellAspect
    sourceWidth*: int
    sourceHeight*: int
    corrected*: bool
      ## Whether the fit differs from the uncorrected one (`rows == cols *
      ## sourceHeight / sourceWidth`). False on a square-celled terminal, which
      ## is a real configuration and not a failure — so a test asserting
      ## "corrected" must pick a non-square cell, and one asserting the
      ## identity case must pick a square one.

const
  DefaultCellAspect* = CellAspect(widthPx: 1, heightPx: 2, source: casDefault)
    ## §2.4's "roughly twice as tall as it is wide", as the configured default
    ## for a terminal that does not answer `CSI 16 t`.
    ##
    ## A RATIO AND NOT A MEASUREMENT. The two integers are not claimed to be
    ## anyone's real cell size in pixels; only their quotient is used, and it is
    ## the ratio the document names. A terminal that DOES answer supplies real
    ## pixel counts and `casReported` says so.

func initCellAspect*(widthPx, heightPx: int;
                     source = casReported): CellAspect =
  ## Refuses a degenerate ratio rather than dividing by zero later. A terminal
  ## that answers `CSI 16 t` with a zero has answered nothing, and the caller's
  ## fallback is `DefaultCellAspect`, which is a decision the caller must make
  ## visibly rather than one this constructor makes silently.
  if widthPx <= 0 or heightPx <= 0:
    return DefaultCellAspect
  CellAspect(widthPx: widthPx, heightPx: heightPx, source: source)

func fitToCells*(sourceWidth, sourceHeight: int; aspect: CellAspect;
                 maxCols, maxRows: int): CellFit =
  ## The largest cell rectangle inside `maxCols x maxRows` whose DISPLAYED
  ## shape matches the source's.
  ##
  ## The identity being solved is
  ##
  ##     (cols * aspect.widthPx) / (rows * aspect.heightPx)
  ##         == sourceWidth / sourceHeight
  ##
  ## i.e. `rows = cols * widthPx * sourceHeight / (heightPx * sourceWidth)`.
  ## At the default 1:2 cell a square source therefore fits in twice as many
  ## columns as rows, which is the §2.4 correction stated as an equation a test
  ## can evaluate independently.
  ##
  ## Both extents are floored at 1: a rendering of a very wide image into a
  ## tall narrow pane still has to occupy a cell, and a zero-row picture is a
  ## blank region, which is what §2.6 and PLAT-9's degradation model both
  ## refuse.
  if sourceWidth <= 0 or sourceHeight <= 0 or maxCols <= 0 or maxRows <= 0:
    return CellFit(cols: 0, rows: 0, aspect: aspect,
                   sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                   corrected: false)
  var cols = maxCols
  var rows = int(round(float(cols) * float(aspect.widthPx) *
                       float(sourceHeight) /
                       (float(aspect.heightPx) * float(sourceWidth))))
  rows = max(rows, 1)
  if rows > maxRows:
    rows = maxRows
    cols = int(round(float(rows) * float(aspect.heightPx) *
                     float(sourceWidth) /
                     (float(aspect.widthPx) * float(sourceHeight))))
    cols = max(1, min(cols, maxCols))
  let uncorrected = max(1, int(round(float(cols) * float(sourceHeight) /
                                     float(sourceWidth))))
  CellFit(cols: cols, rows: rows, aspect: aspect,
          sourceWidth: sourceWidth, sourceHeight: sourceHeight,
          corrected: rows != uncorrected)

func describeAspect*(fit: CellFit): string =
  ## One line for a pane title or a failure message, naming the ratio AND where
  ## it came from.
  "aspect=" & $fit.aspect.widthPx & ":" & $fit.aspect.heightPx &
    "(" & $fit.aspect.source & ") cells=" & $fit.cols & "x" & $fit.rows &
    " source=" & $fit.sourceWidth & "x" & $fit.sourceHeight &
    (if fit.corrected: " corrected" else: " uncorrected")
