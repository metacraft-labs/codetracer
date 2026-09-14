## apps/app_frame_viewer.nim — PLAT-15's Tier-2 child.
##
## NOT A TEST FILE. `ci/lib/test-lane-files.sh` finds `test_*.nim`, so a module
## called anything else under `tests/` is a fixture the suites drive rather than
## a suite the lane runs. `tests/real_terminal/test_real_frame_viewer.nim`
## compiles this with `testing/dual_snap.compileChildApp` and spawns it in a
## real pty.
##
## ## WHY A CHILD AND NOT AN IN-PROCESS TEST
##
## Two things about PLAT-15 cannot be established without a real terminal on
## the other end of a real file descriptor:
##
##   1. **The magnifier's picked pixel is the colour a TERMINAL shows.**
##      `magnifier_test.nim` asserts the `CellGrid` this build produced, which
##      is a claim about a value; `test_real_frame_viewer.nim` reads the same
##      picture back out of `libvterm`'s own cell model as exact RGB numbers,
##      which is a claim about the screen. The two can differ — an emitter that
##      wrote the right cells in the wrong ORDER, or an SGR run that leaked
##      across a row, produces a correct grid and a wrong screen.
##   2. **A degraded pane still draws the rest of itself, ON A TERMINAL.** §2.6
##      is a statement about what a user sees, and "the title and the
##      pixel-history list are still there" is only a statement about a screen
##      once a screen exists.
##
## ## MODES
##
## `argv[1]` selects one, and each writes lines starting with `PLAT15 ` that the
## suite waits for by name — never a sleep. Every number the suite needs in
## order to address a cell is printed by the PRODUCT'S OWN MODEL (the window,
## the zoom, the cursor cell); the COLOUR each cell must carry is recomputed in
## the suite from the fixture's formula. That split is deliberate: the model
## says WHERE, and the formula — which the model never sees — says WHAT.
##
##   `magnify`  build the fixture raster, resolve the capability from the
##              environment, open §5's magnifier over a cell, move the pixel
##              cursor, and emit the overlay.
##   `degrade`  pin `--image-tier=octant`, which PLAT-14 recorded as refusing
##              only at draw time, and print the pane's own text — so the
##              refusal, the remedy, the title's tier and the pixel-history
##              rows can all be read off a terminal.
##   `tier0`    the SAME pane on a terminal that resolves to tier 0, and **NOT
##              magnified**. Added by PLAT-15's landing pass, which found that
##              this child set `magnified = true` unconditionally — so the one
##              tier-0 route any case here exercised was the one
##              `magnifier.magnifierTier` substitutes a cell tier for, and the
##              ordinary path (a graphics terminal, a frame, no magnifier) was
##              painted by nothing in the campaign while `renderCells` raised on
##              it. This mode is that path, on a real terminal.
##
## The capability is always resolved by the product's own
## `resolveImageCapability`; nothing here decides a tier.

import std/[os, posix, strutils]

import ../../../../common/terminal_graphics
import ../../host/image_probe
import ../../app/frame_viewer_binding
import ../../app/theme/capabilities
import ../../app/theme/image_capability
import ../../app/views/frame_viewer

const
  ReadyMarker = "PLAT15 READY"
  FixtureWidth = 16
  FixtureHeight = 12
  OriginRow = 2
  OriginCol = 1
    ## 1-based, as `emit.emitCellGrid` takes them. Printed below so the suite
    ## addresses cells from the child's own answer rather than from a constant
    ## two files would have to keep in step.

func expectedChannel(x, y: int): Rgb =
  ## THE FIXTURE'S FORMULA. `15 * x` over 16 columns and `20 * y` over 12 rows
  ## both stay inside 0..255 and no two pixels share a `(r, g)` pair, so a
  ## magnifier that is off by one in either axis paints a colour the suite can
  ## name.
  Rgb(r: uint8(10 + 15 * x), g: uint8(6 + 20 * y), b: 200'u8)

proc fixtureRaster(): RgbaImage =
  var px = newSeq[byte](FixtureWidth * FixtureHeight * 4)
  for y in 0 ..< FixtureHeight:
    for x in 0 ..< FixtureWidth:
      let c = expectedChannel(x, y)
      let i = (y * FixtureWidth + x) * 4
      px[i] = c.r
      px[i + 1] = c.g
      px[i + 2] = c.b
      px[i + 3] = 255'u8
  initRgbaImage(FixtureWidth, FixtureHeight, px)

proc resolved(pinned = false; tier = itHalfBlock): ImageCapability =
  let env = initTerminalEnv(
    term = getEnv("TERM", ""), colorterm = getEnv("COLORTERM", ""),
    termProgram = getEnv("TERM_PROGRAM", ""), lcAll = getEnv("LC_ALL", ""),
    lcCtype = getEnv("LC_CTYPE", ""), lang = getEnv("LANG", ""),
    noColor = getEnv("NO_COLOR", ""), isTty = isatty(STDOUT_FILENO) == 1)
  var flags = initCapabilityFlags()
  if pinned:
    flags.imageTier = tier
    flags.imageTierPinned = true
  resolveImageCapability(env, readImageEnv(),
                         resolveCapabilities(env, flags), flags)

proc emitLine(text: string) =
  stdout.write(text & "\r\n")
  stdout.flushFile()

proc baseModel(cap: ImageCapability): FrameViewerModel =
  result = initFrameViewerModel()
  result.open = true
  result.frameIndex = 7
  result.frameCount = 40
  result.sourceWidth = FixtureWidth
  result.sourceHeight = FixtureHeight
  result.raster = fixtureRaster()
  result.hasRaster = true
  result.capability = cap
  result.drawCalls = 2
  result.historyRequested = true
  result.historyPixelX = 4
  result.historyPixelY = 4
  result.history = @[
    PixelHistoryRow(drawCallIndex: 0, name: "glClear", passed: true,
                    depth: "pass", stencil: "pass", blend: "applied",
                    cull: "pass"),
    PixelHistoryRow(drawCallIndex: 1, name: "glDrawElements", passed: false,
                    depth: "failed", stencil: "pass", blend: "unchanged",
                    cull: "pass")]

proc runMagnify() =
  let cap = resolved()
  var model = baseModel(cap)
  let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 20, 8)
  model.magnified = true
  model.magnifier = openMagnifier(FixtureWidth, FixtureHeight, fit, cap.tier,
                                  col = 2, row = 1,
                                  viewCols = 20, viewRows = 6)
  # §5's SECOND STAGE, actually exercised: the cursor MOVES, in source pixels,
  # away from where opening it put it. A magnifier asserted only at its opening
  # position would be a magnifier nobody had driven.
  model = model.moveCursorBy(3, 2)
  let grid = renderMagnifier(model.raster, model.magnifier, cap.tier)
  stdout.write(emitCellGrid(grid, cwTrueColor, originRow = OriginRow,
                            originCol = OriginCol))
  stdout.flushFile()
  let (px, py) = model.magnifier.pickedPixel()
  let (cc, cr) = model.magnifier.cursorCell()
  emitLine("\x1b[12;1HPLAT15 TIER " & tierName(cap.tier) &
           " overlay=" & tierName(magnifierTier(cap.tier)))
  emitLine("PLAT15 ORIGIN " & $OriginRow & "," & $OriginCol)
  emitLine("PLAT15 PICK " & $px & "," & $py)
  emitLine("PLAT15 CURSOR " & $cc & "," & $cr)
  emitLine("PLAT15 WINDOW " & $model.magnifier.window.x & "," &
           $model.magnifier.window.y & "," & $model.magnifier.window.width &
           "," & $model.magnifier.window.height)
  emitLine("PLAT15 ZOOM " & $model.magnifier.zoomCols & "," &
           $model.magnifier.zoomRows)
  emitLine("PLAT15 GRID " & $grid.cols & "x" & $grid.rows)
  emitLine(ReadyMarker)

proc runDegrade() =
  ## PLAT-14 RESIDUE 3 ON A TERMINAL. `--image-tier=octant` resolves, and until
  ## PLAT-15 the pane that drew it met a `CellRenderError`. What a user sees
  ## now is a refusal, a remedy, the tier still named in the title, and the
  ## pixel-history list still on the screen.
  let cap = resolved(pinned = true, tier = itOctant)
  var model = baseModel(cap)
  model.gap = model.resolveGap(60, 6)
  # `describeFrameGap` and NOT `degradedMessageFor(frameViewerDegradation(...))`,
  # and the distinction is a boundary rather than a shortcut: a
  # `DegradedStateSnapshot` is the SDK facade's type, and `tests/apps/` carries
  # no `.sdk-consumer` declaration — only `app/` does. The resolution through
  # `PaneDegradation` is asserted where the snapshot is legitimately in scope
  # (`app/tests/test_frame_viewer_pane.nim`); what this child exists to put on a
  # terminal is the TEXT, and `degradedMessageFor` forwards to exactly this
  # function for the row this pane owns.
  model.degradedMessage = describeFrameGap(model.gap)
  var row = OriginRow
  for line in frameViewerText(model, 78, 12):
    stdout.write("\x1b[" & $row & ";1H" & line)
    inc row
  stdout.flushFile()
  emitLine("\x1b[16;1HPLAT15 TIER " & tierName(cap.tier) &
           " gap=" & $model.gap)
  emitLine("PLAT15 DEGRADED " & model.degradedMessage)
  emitLine(ReadyMarker)

proc runTier0() =
  ## THE UNMAGNIFIED TIER-0 PATH, ON A TERMINAL. The capability resolves to
  ## `protocol` from the environment (this child is spawned with
  ## `TERM=xterm-kitty` and a `KITTY_WINDOW_ID`), the model carries a decoded
  ## raster, and NOTHING is magnified — so `drawableTierFor` is `itProtocol` and
  ## the pane has no cell rendering to paint.
  ##
  ## What a user must see is a REPORT: the tier still in the title, the remedy
  ## naming the flag that would draw the frame as cells here, and the
  ## pixel-history list still on the screen — §2.6 on a screen rather than in a
  ## value. Until PLAT-15's landing pass what happened instead was a
  ## `CellRenderError` out of the paint.
  let cap = resolved()
  var model = baseModel(cap)
  model.gap = model.resolveGap(60, 6)
  model.degradedMessage = describeFrameGap(model.gap)
  var row = OriginRow
  for line in frameViewerText(model, 78, 12):
    stdout.write("\x1b[" & $row & ";1H" & line)
    inc row
  stdout.flushFile()
  emitLine("\x1b[16;1HPLAT15 TIER " & tierName(cap.tier) &
           " gap=" & $model.gap)
  emitLine("PLAT15 MAGNIFIED " & $model.magnified)
  emitLine("PLAT15 DEGRADED " & model.degradedMessage)
  emitLine(ReadyMarker)

when isMainModule:
  let mode = if paramCount() >= 1: paramStr(1) else: "magnify"
  case mode
  of "magnify": runMagnify()
  of "degrade": runDegrade()
  of "tier0": runTier0()
  else:
    emitLine("PLAT15 UNKNOWN MODE " & mode)
    emitLine(ReadyMarker)
    quit(2)
  # A short settle before exiting, so the final marker is out of the pty
  # buffer before the descriptor closes. NOT A BARRIER: every assertion in
  # `test_real_frame_viewer.nim` waits for a marker this process wrote, and the
  # suite waits for this process's OWN exit rather than forcing one.
  sleep(150)
