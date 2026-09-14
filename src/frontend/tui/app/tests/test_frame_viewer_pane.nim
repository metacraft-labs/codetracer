## test_frame_viewer_pane.nim — PLAT-15, Tier 1: the frame viewer, the
## magnifier's hand-off to `pixel_history_vm`, and the degradation path, driven
## through REAL ViewModels and the REAL renderer with no terminal attached.
##
## ## WHICH TIER THIS FILE IS, AND WHAT ONLY IT CAN SAY
##
## The campaign runs two tiers and this is the first. `TerminalTestHarness` is
## `isonim_tui`'s own harness — the real renderer, the real compositor and the
## real `HeadlessDriver`, with no pty — so this file can assert
##
##   * that a REAL `FrameViewerVM` and a REAL `PixelHistoryVM` over a real
##     `VisualReplayClient` produce the pane's model, which is the wiring
##     PLAT-14's bound 5 says did not exist;
##   * that the bytes the pane produces are the bytes a DRIVER is handed,
##     compared as an EQUALITY (PLAT-14's standard, kept);
##   * that the coordinate `pixel_history_vm` RECEIVES is the magnifier's,
##     asserted on the request the client recorded rather than on a status.
##
## The second tier — a real pty, a real terminal state machine, the picture
## read back off a terminal's cells — is
## `tests/real_terminal/test_real_frame_viewer.nim`. It is a separate file and
## a separate lane because the two answer different questions, and
## **cross-tier equivalence is blind to a defect both tiers share**: an
## in-process harness and a pty both read what this repository emitted, so only
## a claim about a coordinate compared with the SOURCE IMAGE's own formula can
## catch a magnifier that is consistently wrong.
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## Metacraft policy asks that every mock be justified in a test file's header.
## There is none.
##
##   * `TerminalTestHarness` is not a mock, and this repository has said so
##     since CTUI-2: it is the shipped renderer with no terminal attached.
##   * `FrameViewerVM` and `PixelHistoryVM` are the shipped ViewModels,
##     constructed by their own constructors.
##   * `VisualReplayClient` is a RECORD OF PROCS and its own header publishes
##     this exact use: *"Production code can provide an HTTP-backed client;
##     tests and StoryBook pass a fake client at this same boundary."* Supplying
##     those procs is using the injection point, not substituting for the
##     component — the ViewModel under test is real, its signals are real, and
##     the futures are the platform's own.
##   * The raster is built in code rather than read from a PNG, for
##     `cell_render_test.nim`'s reason: this build has no PNG decoder, so
##     reading one would mean adding a dependency in order to test a function
##     that does not use it.
##
## ## COUNTED ASSERTIONS (§4c) AND TEMPLATES, NEVER PROCS (§13)
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1. Every assertion below goes through `ck`/`ckEq`,
## which are templates.

import std/[options, strutils, unittest]

import isonim/core/async_compat
import isonim_tui

import codetracer_embed

import ../frame_viewer_binding
import ../theme/capabilities
import ../theme/image_capability
import ../views/shell

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 145

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

# ---------------------------------------------------------------------------
# The fixture, and its formula
# ---------------------------------------------------------------------------

const
  FrameWidth = 32
  FrameHeight = 24

func expectedChannel(x, y: int): Rgb =
  ## THE FIXTURE'S FORMULA, evaluated in this file — never read back out of the
  ## raster the renderer was handed. Every pixel is a different colour, so "the
  ## magnifier shows pixel (x, y)" is falsifiable.
  Rgb(r: uint8(20 + 5 * x), g: uint8(7 + 9 * y),
      b: uint8(60 + ((x * 3 + y * 11) mod 100)))

proc frameRaster(): RgbaImage =
  var px = newSeq[byte](FrameWidth * FrameHeight * 4)
  for y in 0 ..< FrameHeight:
    for x in 0 ..< FrameWidth:
      let c = expectedChannel(x, y)
      let i = (y * FrameWidth + x) * 4
      px[i] = c.r
      px[i + 1] = c.g
      px[i + 2] = c.b
      px[i + 3] = 255'u8
  initRgbaImage(FrameWidth, FrameHeight, px)

# ---------------------------------------------------------------------------
# The client's own injection point
# ---------------------------------------------------------------------------

type
  RecordedClient = ref object
    ## The requests the ViewModels actually issued. Asserting on THESE rather
    ## than on a ViewModel's own signal is what makes "the coordinate reached
    ## `pixel_history_vm`" a claim about an effect: a signal could be written
    ## by the caller, and a request could not.
    client: VisualReplayClient
    pixelRequests: seq[(int, int, int)]
    drawCallRequests: int

proc recordingClient(): RecordedClient =
  result = RecordedClient(pixelRequests: @[], drawCallRequests: 0)
  let rec = result
  rec.client = VisualReplayClient(
    playerUrl: "http://player.test/",
    getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
      newCompletedFuture(VisualReplayInfo(frameCount: 40, width: FrameWidth,
                                          height: FrameHeight)),
    getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(VisualReplayFrame(imageSrc: "data:image/png;base64,AAAA",
                                           geid: some(geid), frame: some(3),
                                           width: FrameWidth,
                                           height: FrameHeight)),
    getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(VisualReplayFrame(imageSrc: "data:image/png;base64,AAAA",
                                           geid: some(uint64(900 + frame)),
                                           frame: some(frame),
                                           width: FrameWidth,
                                           height: FrameHeight)),
    getFrameByDrawProc: proc(draw: int): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(VisualReplayFrame(imageSrc: "data:image/png;base64,AAAA",
                                           geid: some(uint64(800 + draw)),
                                           frame: some(3),
                                           width: FrameWidth,
                                           height: FrameHeight)),
    getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
      inc rec.drawCallRequests
      newCompletedFuture(@[
        VisualReplayDrawCall(index: 0, geid: 100'u64, name: "glClear",
                             pipeline: "clear"),
        VisualReplayDrawCall(index: 1, geid: 101'u64, name: "glDrawElements",
                             pipeline: "mesh")]),
    getPixelHistoryProc: proc(x, y, frame: int):
        VisualReplayFuture[seq[VisualReplayPixelHistoryEntry]] =
      rec.pixelRequests.add (x, y, frame)
      newCompletedFuture(@[
        VisualReplayPixelHistoryEntry(
          geid: 100'u64, drawCallIndex: 0, passed: true,
          testStatus: VisualReplayPixelTestStatus(
            depth: "pass", stencil: "pass", blend: "applied", cull: "pass")),
        VisualReplayPixelHistoryEntry(
          geid: 101'u64, drawCallIndex: 1, passed: false,
          failureReason: "depth_failed",
          testStatus: VisualReplayPixelTestStatus(
            depth: "failed", stencil: "pass", blend: "unchanged",
            cull: "pass"))]),
    getShaderDebugProc: proc(request: VisualReplayShaderDebugRequest):
        VisualReplayFuture[VisualReplayShaderDebugInfo] =
      newCompletedFuture(VisualReplayShaderDebugInfo(shaderStage: "fragment")))

# ---------------------------------------------------------------------------
# Capabilities, resolved by the product's own resolver
# ---------------------------------------------------------------------------

proc capabilityFor(term: string; pinned = false;
                   tier = itHalfBlock): ImageCapability =
  ## The capability a terminal resolves to, through
  ## `resolveImageCapability` — the product's own function, never a constructed
  ## `ImageCapability`. A hand-built one would let this suite pass against a
  ## resolver that had stopped resolving.
  let env = initTerminalEnv(term = term, colorterm = "truecolor",
                            lang = "en_US.UTF-8")
  var flags = initCapabilityFlags()
  if pinned:
    flags.imageTier = tier
    flags.imageTierPinned = true
  let ienv =
    if term == "xterm-kitty": initImageEnv(kittyWindowId = "1")
    else: initImageEnv()
  resolveImageCapability(env, ienv, resolveCapabilities(env, flags), flags)

proc loadedFrames(rec: RecordedClient): FrameViewerVM =
  result = createFrameViewerVM(rec.client)
  result.loadInfo()
  result.loadFrameByIndex(3)
  drainPlatformCallbacks()

# ---------------------------------------------------------------------------

suite "PLAT-15 §4: the pane declares its tier, the frame and the size":

  test "the title names the frame, its pixel extent and the resolved tier":
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    let cap = capabilityFor("xterm-256color")
    let model = frameViewerModelFor(frames, history, cap,
                                    initDegradedStateSnapshot(),
                                    raster = frameRaster(), hasRaster = true,
                                    pictureCols = 60, pictureRows = 10)
    let title = model.titleText()
    checkpoint(title)
    # THE VIEWMODEL'S OWN NUMBERS reached the pane.
    ckEq model.frameIndex, 3
    ckEq model.frameCount, 40
    ckEq model.sourceWidth, FrameWidth
    ckEq model.sourceHeight, FrameHeight
    ck title.contains("frame 3/40")
    ck title.contains("32x24px")
    # §4: THE TIER IS IN THE TITLE, as `describe`'s own string and not a second
    # spelling of it.
    ck title.contains(describe(cap))
    ck title.contains("image-tier=half-block")
    # …and the tier a DIFFERENT terminal resolves to is a DIFFERENT title, so
    # the assertion above is about this capability and not about any string
    # being present (§7a).
    let kitty = capabilityFor("xterm-kitty")
    ckEq kitty.tier, itProtocol
    var kittyModel = model
    kittyModel.capability = kitty
    ck kittyModel.titleText().contains("image-tier=protocol")
    ck not kittyModel.titleText().contains("image-tier=half-block")

  test "a magnified pane names the OVERLAY's tier when it differs":
    # A tier-0 terminal magnifies at tier 1 (`magnifier.magnifierTier`), and a
    # title that still said `protocol` over a half-block picture would be the
    # untrustworthy screen §4's sentence exists to prevent.
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    let model = frameViewerModelFor(frames, history, capabilityFor("xterm-kitty"),
                                    initDegradedStateSnapshot(),
                                    raster = frameRaster(), hasRaster = true,
                                    pictureCols = 60, pictureRows = 10)
    let magnified = model.openMagnifierAt(4, 2, viewCols = 40, viewRows = 8)
    ck magnified.magnified
    ckEq magnified.drawableTierFor(), itHalfBlock
    ck magnified.titleText().contains("magnifier=half-block")
    # THE TWIN: unmagnified, the same model names no overlay tier.
    ck not model.titleText().contains("magnifier=")

suite "PLAT-15 §5: the coordinate pixel_history_vm receives is the magnifier's":

  test "the picked pixel reaches the client as the pixel the magnifier named":
    # THE HAND-OFF, asserted on the REQUEST the client recorded rather than on
    # a signal the caller could have written.
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    let model = frameViewerModelFor(frames, history,
                                    capabilityFor("xterm-256color"),
                                    initDegradedStateSnapshot(),
                                    raster = frameRaster(), hasRaster = true,
                                    pictureCols = 60, pictureRows = 10)
    var magnified = model.openMagnifierAt(5, 3, viewCols = 40, viewRows = 8)
    magnified = magnified.moveCursorBy(2, -1)
    let (wantX, wantY) = magnified.magnifier.pickedPixel()
    ckEq rec.pixelRequests.len, 0
    ck requestPixelHistory(history, magnified)
    drainPlatformCallbacks()
    ckEq rec.pixelRequests.len, 1
    ckEq rec.pixelRequests[0], (wantX, wantY, 3)
    # AND THE VIEWMODEL AGREES WITH THE REQUEST.
    ck history.selectedPixel.val.isSome
    ckEq history.selectedPixel.val.get.x, wantX
    ckEq history.selectedPixel.val.get.y, wantY
    ckEq history.entries.val.len, 2

  test "without the magnification step there is no request at all":
    # §5: "The coordinate is never inferred from a cell position without the
    # magnification step." The enforcement is that there is no overload taking
    # a cell — this is the half that can be tested: an unmagnified model
    # produces NO request, and the magnified twin above produces one, through
    # the same function.
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    let model = frameViewerModelFor(frames, history,
                                    capabilityFor("xterm-256color"),
                                    initDegradedStateSnapshot(),
                                    raster = frameRaster(), hasRaster = true,
                                    pictureCols = 60, pictureRows = 10)
    ck not model.magnified
    ck not requestPixelHistory(history, model)
    drainPlatformCallbacks()
    ckEq rec.pixelRequests.len, 0
    ck history.selectedPixel.val.isNone

  test "a magnifier over an undecoded frame is refused, not guessed":
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    let model = frameViewerModelFor(frames, history,
                                    capabilityFor("xterm-256color"),
                                    initDegradedStateSnapshot(),
                                    pictureCols = 60, pictureRows = 10)
    ck not model.hasRaster
    var raised = false
    try:
      discard model.openMagnifierAt(2, 1, viewCols = 40, viewRows = 8)
    except MagnifierError as e:
      raised = true
      ck e.msg.contains("no decoded frame")
      ck e.msg.contains("PNG or JPEG decoder")
    ck raised

  test "the magnifier CURSOR is on the screen, in an attribute every rung has":
    # §2.6: "It never silently omits an overlay, a selection marker or a
    # magnifier cursor." The marker is `reverse` and not a colour, because
    # `reverse` is the one attribute that survives every rung of CTUI-11's
    # ladder including monochrome — a coloured cursor would vanish on exactly
    # the terminal where the picture is already coarsest.
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    let model = frameViewerModelFor(frames, history,
                                    capabilityFor("xterm-256color"),
                                    initDegradedStateSnapshot(),
                                    raster = frameRaster(), hasRaster = true,
                                    pictureCols = 60, pictureRows = 10)
    let magnified = model.openMagnifierAt(4, 2, viewCols = 40, viewRows = 8)
    let grid = renderMagnifier(magnified.raster, magnified.magnifier,
                               magnified.capability.tier)
    let (cc, cr) = magnified.magnifier.cursorCell()
    let row = gridRowSpans(grid, cr, 40, cc, cr,
                           magnified.magnifier.zoomCols,
                           magnified.magnifier.zoomRows)
    # THE CURSOR'S OWN CELLS CARRY IT — as many cells as the zoom says one
    # source pixel occupies, so the marker covers the WHOLE pixel rather than
    # half of it.
    var reversed = 0
    var plain = 0
    for span in row:
      if span.style.reverse: inc reversed
      else: inc plain
    checkpoint("reversed spans " & $reversed & ", plain " & $plain)
    ckEq reversed, magnified.magnifier.zoomCols
    # …AND THE REST OF THE ROW DOES NOT, so "the cursor is marked" is
    # distinguishable from "this row is all reverse" (§7a).
    ck plain > 0
    # A ROW THE CURSOR IS NOT ON carries no marker at all, through the same
    # function.
    let otherRow = gridRowSpans(grid, (cr + magnified.magnifier.zoomRows) mod
                                       grid.rows,
                                40, cc, cr, magnified.magnifier.zoomCols,
                                magnified.magnifier.zoomRows)
    var otherReversed = 0
    for span in otherRow:
      if span.style.reverse: inc otherReversed
    ckEq otherReversed, 0

suite "PLAT-15 §2.6: a pane that cannot draw says why, and keeps drawing":

  test "an octant pin degrades through pdDependencyMissing, picture only":
    # PLAT-14 RESIDUE 3, ARRIVING AT A USER. `--image-tier=octant` resolved
    # fine and refused only at draw time, where a pane met a `CellRenderError`.
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    history.loadPixelHistory(7, 5, 3)
    drainPlatformCallbacks()
    let cap = capabilityFor("xterm-256color", pinned = true, tier = itOctant)
    ckEq cap.tier, itOctant
    let model = frameViewerModelFor(frames, history, cap,
                                    initDegradedStateSnapshot(),
                                    raster = frameRaster(), hasRaster = true,
                                    pictureCols = 60, pictureRows = 10)
    ckEq model.gap, fdgTierNotDrawable
    # §8.2's REUSE: `resolveDegradation`, the existing precedence, and
    # `pdDependencyMissing`. No row was added to `PaneDegradation`.
    ckEq frameDependencyState(model.gap), pdsUnsupported
    ckEq frameViewerDegradation(initDegradedStateSnapshot(), model.gap),
         pdDependencyMissing
    # WHAT IS MISSING AND HOW TO GET IT.
    checkpoint(model.degradedMessage)
    ck model.degradedMessage.contains("octant")
    ck model.degradedMessage.contains("--image-tier=sextant")
    ck model.degradedMessage.contains("--image-tier=braille")
    # AND THE REST OF THE PANE STILL RENDERS. The picture region went to zero;
    # the title and the pixel-history list did not.
    let screen = frameViewerScreen(model, 70, 16)
    checkpoint("picture rows " & $screen.pictureRows & ", degraded rows " &
               $screen.degradedRows & ", history rows " & $screen.historyRows)
    ckEq screen.pictureRows, 0
    ck screen.degradedRows >= 2
    ck screen.historyRows > 0
    ck rowText(screen.rows[0]).contains("FRAME VIEWER")
    ck rowText(screen.rows[0]).contains("image-tier=octant")
    var sawHistoryTitle = false
    for row in screen.rows:
      if rowText(row).contains("PIXEL HISTORY"):
        sawHistoryTitle = true
    ck sawHistoryTitle

  test "the POSITIVE TWIN: a drawable tier draws, same model, same pane":
    # Without this the case above is satisfied by a pane that never draws.
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    history.loadPixelHistory(7, 5, 3)
    drainPlatformCallbacks()
    let model = frameViewerModelFor(frames, history,
                                    capabilityFor("xterm-256color"),
                                    initDegradedStateSnapshot(),
                                    raster = frameRaster(), hasRaster = true,
                                    pictureCols = 60, pictureRows = 10)
    ckEq model.gap, fdgNone
    ckEq frameDependencyState(model.gap), pdsSatisfied
    ckEq frameViewerDegradation(initDegradedStateSnapshot(), model.gap), pdNone
    ckEq model.degradedMessage, ""
    let screen = frameViewerScreen(model, 70, 16)
    ck screen.pictureRows > 0
    ckEq screen.degradedRows, 0
    ck screen.historyRows > 0
    ckEq screen.tierDrawn, itHalfBlock
    # THE WORK BOUND, as an EQUALITY in the one unit this package counts —
    # candidate masks evaluated. No timing is asserted anywhere in this file.
    ckEq screen.candidatesEvaluated,
         screen.pictureCols * screen.pictureRows *
         candidatesPerCell(itHalfBlock)

  test "an ENCODED frame on a cell terminal is PLAT-14's bound 3, reported":
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    let model = frameViewerModelFor(frames, history,
                                    capabilityFor("xterm-256color"),
                                    initDegradedStateSnapshot(),
                                    pictureCols = 60, pictureRows = 10)
    # The ViewModel's `frameImageSrc` is a `data:` URL, so the pane has a
    # LENGTH in bytes and no pixels.
    ck model.encodedBytes > 0
    ck not model.hasRaster
    ckEq model.gap, fdgNoDecoder
    ckEq frameDependencyState(model.gap), pdsUnsupported
    ck model.degradedMessage.contains("no PNG or JPEG decoder")
    ck model.degradedMessage.contains("Kitty or iTerm2")
    # AND THE SAME ENCODED FRAME ON A KITTY TERMINAL MEETS A DIFFERENT WALL —
    # which is what keeps the gap above from being "this pane refuses every
    # encoded frame" (§7a). Tier 0 needs no decoder IN THIS PROCESS, and this
    # pane still cannot PAINT it, because a tier-0 frame is a payload rather
    # than cells. The REASON changes, and a gap is nothing but its reason.
    #
    # THIS ASSERTION WAS `ckEq kitty.gap, fdgNone` UNTIL PLAT-15'S LANDING PASS.
    # It was the only case in three files that put a tier-0 model past
    # `resolveGap`, it never painted one, and the pane it blessed raised a
    # `CellRenderError` out of `shellScreen` — see the case below, which paints.
    let kitty = frameViewerModelFor(frames, history, capabilityFor("xterm-kitty"),
                                    initDegradedStateSnapshot(),
                                    pictureCols = 60, pictureRows = 10)
    ckEq kitty.capability.tier, itProtocol
    ckEq kitty.gap, fdgProtocolNotPainted
    ck kitty.gap != model.gap
    ck not kitty.degradedMessage.contains("no PNG or JPEG decoder")
    ck kitty.degradedMessage.contains("paints cells")
    ck kitty.degradedMessage.contains("--image-tier=half-block")
    # THE POSITIVE TWIN FOR THE DECODER GAP, through the same function: the same
    # cell terminal with a DECODED raster draws, so `fdgNoDecoder` is about the
    # absent decoder and not about this pane never drawing an encoded frame.
    let decoded = frameViewerModelFor(frames, history,
                                      capabilityFor("xterm-256color"),
                                      initDegradedStateSnapshot(),
                                      raster = frameRaster(), hasRaster = true,
                                      pictureCols = 60, pictureRows = 10)
    ckEq decoded.gap, fdgNone

  test "an UNMAGNIFIED tier-0 pane reports, keeps drawing, and does not raise":
    # THE CASE THIS FILE DID NOT HAVE. Every paint and emit case in all three
    # PLAT-15 files was `xterm-256color`; the one `xterm-kitty` paint is
    # MAGNIFIED, so it routes through `magnifierTier(itProtocol) = itHalfBlock`
    # and is safe, and the Tier-2 child sets `magnified = true` unconditionally.
    # So the ordinary tier-0 path — a graphics terminal, a frame, no magnifier —
    # was painted by nothing, and `renderCells` raised on it.
    #
    # Both shapes are driven, because they reach the refusal by different
    # routes: a DECODED raster (the tier is the only reason) and the ENCODED
    # payload the binding actually produces (`frameImageSrc` is a string, so
    # nothing in this repository walks through `rasterFrame` today).
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    history.loadPixelHistory(7, 5, 3)
    drainPlatformCallbacks()
    let kitty = capabilityFor("xterm-kitty")
    ckEq kitty.tier, itProtocol
    for hasPixels in [true, false]:
      let model = frameViewerModelFor(
        frames, history, kitty, initDegradedStateSnapshot(),
        raster = (if hasPixels: frameRaster() else: RgbaImage()),
        hasRaster = hasPixels, pictureCols = 60, pictureRows = 10)
      checkpoint("hasRaster " & $hasPixels & " -> " & $model.gap)
      ck not model.magnified
      ckEq model.drawableTierFor(), itProtocol
      ckEq model.gap, fdgProtocolNotPainted
      ckEq frameDependencyState(model.gap), pdsUnsupported
      ckEq frameViewerDegradation(initDegradedStateSnapshot(), model.gap),
           pdDependencyMissing
      # §2.6: THE PICTURE REGION SAYS WHY AND THE REST OF THE PANE IS DRAWN.
      # This whole block used to raise `CellRenderError` from `renderCells`.
      let screen = frameViewerScreen(model, 70, 16)
      ckEq screen.pictureRows, 0
      ckEq screen.candidatesEvaluated, 0
      ck screen.degradedRows >= 2
      ck screen.historyRows > 0
      # §4: THE TIER IS STILL IN THE TITLE, and it is the one that resolved.
      ck rowText(screen.rows[0]).contains("image-tier=protocol")
      var sawRemedy = false
      for row in screen.rows:
        if rowText(row).contains("--image-tier=half-block"):
          sawRemedy = true
      ck sawRemedy
      # AND THROUGH THE SHELL, which is the WIRED path and the one the
      # exception escaped: `paintFrameViewer` is called by `shellScreen` and a
      # raise there takes the whole screen, not one pane.
      var shell = newShellModel(100, 30)
      shell.frameViewer = model
      let painted = shellScreen(shell, 100, 30)
      ck painted.frameViewerOverlay.width > 0
      ckEq painted.frameViewer.pictureRows, 0
      ck painted.frameViewer.degradedRows >= 2
    # THE POSITIVE TWIN, THROUGH THE SAME SHELL: a cell terminal with the same
    # raster paints a picture, so "the shell survived" is distinguishable from
    # "the shell draws no frame viewer at all" (§7a).
    var drawable = newShellModel(100, 30)
    drawable.frameViewer = frameViewerModelFor(
      frames, history, capabilityFor("xterm-256color"),
      initDegradedStateSnapshot(), raster = frameRaster(), hasRaster = true,
      pictureCols = 60, pictureRows = 10)
    let drawn = shellScreen(drawable, 100, 30)
    ckEq drawable.frameViewer.gap, fdgNone
    ck drawn.frameViewer.pictureRows > 0
    ckEq drawn.frameViewer.tierDrawn, itHalfBlock
    # AND THE EMITTER REFUSES THE SAME TIER-0 MODEL BY THE SAME GAP — one
    # refusal, from `resolveGap`, rather than a second `itProtocol` test of its
    # own (which is now unreachable and gone).
    let tier0 = frameViewerModelFor(
      frames, history, kitty, initDegradedStateSnapshot(),
      raster = frameRaster(), hasRaster = true,
      pictureCols = 60, pictureRows = 10)
    var raised = false
    try:
      discard emitFrameViewerPicture(tier0, 60, 11)
    except EmitError as e:
      raised = true
      checkpoint(e.msg)
      ck e.msg.contains("protocol-not-painted")
      ck e.msg.contains("not painted as cells")
    ck raised

  test "no player at all is pdsABSENT, which is a different remedy":
    # `PluginDependencyState`'s own doc: "telling a user to install a tool on a
    # host that could not run it either way is the retry that cannot succeed".
    # This pane is the first consumer in the tree whose fifth axis carries BOTH
    # values, and the two are asserted side by side so the distinction is a
    # measurement rather than a typed constant.
    let rec = recordingClient()
    let history = createPixelHistoryVM(rec.client)
    let model = frameViewerModelFor(nil, history, capabilityFor("xterm-256color"),
                                    initDegradedStateSnapshot(),
                                    pictureCols = 60, pictureRows = 10)
    ckEq model.gap, fdgPlayerAbsent
    ckEq frameDependencyState(model.gap), pdsAbsent
    ck frameDependencyState(fdgNoDecoder) != frameDependencyState(fdgPlayerAbsent)
    ck model.degradedMessage.contains("ct-gfx-player")
    ckEq frameViewerDegradation(initDegradedStateSnapshot(), model.gap),
         pdDependencyMissing

  test "the session's own rows still OUTRANK this pane's, one precedence":
    # There is no second precedence: `DegradationPrecedence` is the array that
    # already decides, and a trace that will not replay outranks a frame that
    # will not draw. Asserted with BOTH conditions true at once, which is the
    # only state that can tell one precedence from two.
    var snapshot = initDegradedStateSnapshot()
    snapshot.availability = raUnreplayable
    ckEq frameViewerDegradation(snapshot, fdgNoDecoder),
         pdPermanentlyUnreplayable
    # …and with the session healthy the same gap resolves to this pane's row.
    ckEq frameViewerDegradation(initDegradedStateSnapshot(), fdgNoDecoder),
         pdDependencyMissing
    # THE SENSITIVITY SET IS A SUBSET OF WHAT ALREADY EXISTS: no row was added
    # to `PaneDegradation` by this milestone.
    var union: set[PaneDegradation] = {}
    for s in AllPaneDegradations:
      union = union + s
    for row in FrameViewerPaneDegradations:
      ck row in union

suite "PLAT-15: the bytes reach a driver":

  test "a cell-tier picture arrives at the headless driver, byte for byte":
    let harness = newTerminalTestHarness(80, 24)
    defer: harness.dispose()
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    let model = frameViewerModelFor(frames, history,
                                    capabilityFor("xterm-256color"),
                                    initDegradedStateSnapshot(),
                                    raster = frameRaster(), hasRaster = true,
                                    pictureCols = 60, pictureRows = 10)
    let emitted = emitFrameViewerPicture(model, 60, 11)
    ckEq emitted.tier, itHalfBlock
    ckEq emitted.protocol, ipNone
    ck emitted.emittedBytes > 0
    harness.clearBytesEmitted()
    harness.driver.writeRaw(emitted.bytes)
    # THE DRIVER SAW EXACTLY THOSE BYTES.
    ckEq harness.bytesEmitted(), emitted.bytes
    # §3: A CELL TIER LEAVES NO GRAPHICS ESCAPE ON SCREEN — with the positive
    # twin first, through the SAME predicate, so "found nothing" is not what
    # satisfies it (§7a).
    ck containsGraphicsEscape(kittyTransmit(@[1'u8, 2, 3], 4))
    ck not containsGraphicsEscape(harness.bytesEmitted())
    # A TRUE-COLOUR CELL EMISSION CARRIES SGR. Without this the line above is
    # satisfied by an emitter that produced nothing at all.
    ck harness.bytesEmitted().contains("\x1b[38;2;")

  test "a pane that cannot draw refuses to emit rather than emitting nothing":
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    let model = frameViewerModelFor(
      frames, history,
      capabilityFor("xterm-256color", pinned = true, tier = itOctant),
      initDegradedStateSnapshot(), raster = frameRaster(), hasRaster = true,
      pictureCols = 60, pictureRows = 10)
    var raised = false
    try:
      discard emitFrameViewerPicture(model, 60, 11)
    except EmitError as e:
      raised = true
      ck e.msg.contains("tier-not-drawable")
      ck e.msg.contains("--image-tier=sextant")
    ck raised

suite "PLAT-15: the overlay in the shell":

  test "closed, the frame viewer changes no cell of the screen":
    var model = newShellModel(100, 30)
    let closed = shellScreen(model, 100, 30)
    ck not model.frameViewer.open
    ckEq closed.frameViewerOverlay, CellArea()
    ckEq closed.frameViewer.pictureRows, 0
    # OPENING IT CHANGES THE SCREEN — so "closed changes nothing" is a
    # measurement and not a tautology.
    let rec = recordingClient()
    let frames = rec.loadedFrames()
    let history = createPixelHistoryVM(rec.client)
    model.frameViewer = frameViewerModelFor(
      frames, history, capabilityFor("xterm-256color"),
      initDegradedStateSnapshot(), raster = frameRaster(), hasRaster = true,
      pictureCols = 60, pictureRows = 10)
    let opened = shellScreen(model, 100, 30)
    ck opened.frameViewerOverlay.width > 0
    ck opened.frameViewer.pictureRows > 0
    ck opened.rows != closed.rows
    # AND THE CHANGE IS CONFINED TO THE OVERLAY'S OWN RECTANGLE. An overlay
    # that repainted a row it does not own would be CTUI-3's "silently
    # misdrawn screen".
    let rect = opened.frameViewerOverlay
    var rowsOutside = 0
    for r in 0 ..< closed.rows.len:
      if r < rect.row or r >= rect.row + rect.height:
        ckEq opened.rows[r], closed.rows[r]
        inc rowsOutside
    ck rowsOutside > 0
    checkpoint("rows outside the overlay compared: " & $rowsOutside)

suite "PLAT-15: the tally":

  test "every assertion in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    ckEq countedAssertions, ExpectedAssertions
