## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reaches `codetracer_embed` — the sanctioned facade
## — and never `viewmodel/*` directly.
##
## app/frame_viewer_binding.nim — PLAT-15. The ONE place that turns
## `FrameViewerVM` and `PixelHistoryVM` into a `FrameViewerModel`, and the ONE
## place in the terminal's image path that names a `PaneDegradation`.
##
## ## WHY THIS EXISTS AS ITS OWN MODULE
##
## `app/source_binding.nim`'s reasons, unchanged: the pane is a pure function
## of a value, something has to read the ViewModels, and putting that in the
## view would take away the three properties the split buys — the pane could no
## longer be asserted without a replay player, two frames could no longer be
## compared as values, and the pane's picture would stop being a property of a
## field a reader can see.
##
## ## §8.2's REUSE, AND NO ROW IS ADDED TO `PaneDegradation`
##
## PLAT-9 established the rule and PLAT-12 restated it for a second subject:
## *"inventing a parallel 'plugin unavailable' banner would be a second
## mechanism saying the same thing worse"*. A frame viewer that cannot draw is
## a third subject with the same shape, so the answer is the same three things
## and no fourth: `resolveDegradation`, the existing precedence, and
## `pdDependencyMissing`.
##
## **There is no second resolver and no second precedence.**
## `store/value_media_degradation.nim` is the module this one is modelled on,
## line for line: a sensitivity set, a function from this subject's own gap to
## `PluginDependencyState`, a snapshot builder that fills the fifth axis, and
## `resolveDegradation` over the array that already decides which of two
## simultaneous conditions wins.
##
## ## `pdsAbsent` AND `pdsUnsupported` MEAN DIFFERENT THINGS HERE, AND BOTH OCCUR
##
## `PluginDependencyState`'s doc comment states the distinction and warns what
## collapsing it costs: *"telling a user to install a tool on a host that could
## not run it either way is the retry that cannot succeed §14 forbids."*
## PLAT-12's value path answers `pdsUnsupported` for every gap it has, and
## records that this is honest because none of ITS gaps has an install-shaped
## remedy. This subject has one that does:
##
##   * `fdgPlayerAbsent` -> **`pdsAbsent`**. `ct-gfx-player` reconstructs the
##     frame in a separate process against a real GPU; starting it is a thing a
##     user can do, and the remedy says so.
##   * `fdgNoDecoder`, `fdgTierNotDrawable`, `fdgProtocolNotPainted`,
##     `fdgNoRoomForPicture` -> **`pdsUnsupported`**. No PNG decoder in this
##     build, no verified octant table in this build, no tier-0 transmitter
##     behind this pane in this build, no rows in this rectangle. Nothing a user
##     installs changes any of the four.
##
##     `fdgProtocolNotPainted` is the one that reads oddest and is still right:
##     the terminal is the BEST one for the job and the pane still cannot paint
##     a tier-0 frame, because a tier-0 frame is a payload rather than cells
##     (`views/frame_viewer.nim`'s header). `pdsAbsent` would tell a user to
##     start something, and there is nothing to start — the remedy is an
##     `--image-tier` flag, which is a decision rather than an installation.
##
## So this is the first consumer in the tree for which the fifth axis carries
## two values, which is what makes the distinction a measurement rather than a
## typed constant.
##
## ## WHAT IT READS
##
##   * `FrameViewerVM` — `currentFrame`, `frameCount`, `frameWidth`,
##     `frameHeight`, `drawCalls`, `selectedDrawCall`, `visualReplayAvailable`
##     and `frameImageSrc`.
##
##     **`frameImageSrc` IS A STRING AND NOT PIXELS, and that is a finding
##     rather than a shortcut.** `VisualReplayFrame` carries `imageSrc` — a URL
##     or a `data:` URL — and `src/frontend/viewmodel/` has no raster type at
##     all. A cell tier consumes a RASTER (`terminal_graphics/raster.nim`), and
##     this build has no PNG or JPEG decoder, so on a terminal with no graphics
##     protocol the honest answer is PLAT-14's bound 3 arriving at a user:
##     `fdgNoDecoder`, through `pdDependencyMissing`, with the rest of the pane
##     still drawn. `rasterFrame` is the door a raster arrives through when one
##     does; nothing in this repository walks through it today and the
##     milestone says so rather than shipping a decoder nobody wrote.
##   * `PixelHistoryVM` — `entries`, `selectedEntry`, `selectedPixel`. §6.1's
##     list, with pass/fail for depth, stencil, blend and cull.
##   * an `ImageCapability` — resolved by the HOST, because the probe is a
##     terminal round trip and this layer may not do I/O. It is a PARAMETER for
##     `app/theme/image_capability.nim`'s own reason: a module that performed
##     its own probe could not be handed a failed one, and the interesting case
##     is the failed one.
##
## ## NO MOCKS
##
## Nothing here stands in for anything. `app/tests/test_frame_viewer_pane.nim`
## drives real `FrameViewerVM` and `PixelHistoryVM` instances over a real
## `VisualReplayClient` whose four procs are supplied by the test — which is
## the client's OWN published injection point ("Production code can provide an
## HTTP-backed client; tests and StoryBook pass a fake client at this same
## boundary"), not a substitute for one.

import std/options

import codetracer_embed

import ./views/frame_viewer

export frame_viewer

const
  FrameViewerPaneDegradations*: set[PaneDegradation] = {
    pdPermanentlyUnreplayable,
    pdReplayWindowExpired,
    pdEngineUnavailable,
    pdDependencyMissing,
  }
    ## The rows THIS pane renders a treatment for.
    ##
    ## The three that mean the execution cannot be seen at all, plus the draw
    ## gap. It is NOT sensitive to truncation, divergence or source
    ## verification, on `ContributedPaneDegradations`' reasoning: a
    ## reconstructed frame at a tick inside the recording is not made wrong by
    ## the recording ending early, and a banner that said so would train a user
    ## to ignore the one that matters.
    ##
    ## A SUBSET OF `AllPaneDegradations`' UNION and not a new member of it —
    ## `resolveDegradation` takes the set as a parameter precisely so a caller
    ## can bring its own, and every row here is already claimed by a pane in
    ## that array. No row was added to `PaneDegradation` and
    ## `store/degraded_state.nim` is untouched by this milestone.

func frameDependencyState*(gap: FrameDrawGap): PluginDependencyState =
  ## The fifth axis, for one frame viewer. See this module's header on why
  ## exactly one of the four gaps is `pdsAbsent`.
  case gap
  of fdgNone: pdsSatisfied
  of fdgPlayerAbsent: pdsAbsent
  of fdgNoDecoder, fdgTierNotDrawable, fdgProtocolNotPainted,
     fdgNoRoomForPicture: pdsUnsupported

func frameViewerSnapshot*(core: DegradedStateSnapshot;
                          gap: FrameDrawGap): DegradedStateSnapshot =
  ## The session's four axes, plus THIS pane's dependency axis.
  ##
  ## `store/value_media_degradation.valueSnapshot`'s shape, and for the same
  ## reason: ONE snapshot, so `resolveDegradation` is the same call every other
  ## consumer makes and the precedence between "the trace will not replay" and
  ## "this frame will not draw" is decided once, in the array that already
  ## decides it.
  result = core
  result.dependency = frameDependencyState(gap)

func frameViewerDegradation*(core: DegradedStateSnapshot;
                             gap: FrameDrawGap): PaneDegradation =
  ## §8.2's reuse, spelled out. There is no second resolver, no second enum and
  ## no second precedence.
  resolveDegradation(frameViewerSnapshot(core, gap),
                     FrameViewerPaneDegradations)

func describeFrameGap*(gap: FrameDrawGap): string =
  ## §8.2's "what is missing and how to get it", as the one line the pane
  ## prints.
  ##
  ## The REMEDY half is `views/frame_viewer.remedyFor` and is not re-worded
  ## here (Verification-Harness-Traps §14): the pane prints it when the binding
  ## supplied no message, and two spellings of one remedy would let the
  ## degraded pane and the degraded report say different things about the same
  ## gap.
  case gap
  of fdgNone: ""
  of fdgPlayerAbsent:
    "No reconstructed frame for this position — " & remedyFor(gap) & "."
  of fdgNoDecoder:
    "This frame arrived as an encoded image and this terminal draws cells — " &
    remedyFor(gap) & "."
  of fdgTierNotDrawable:
    "The pinned image tier cannot draw — " & remedyFor(gap) & "."
  of fdgProtocolNotPainted:
    "This terminal draws true pixels and this pane paints cells — " &
    remedyFor(gap) & "."
  of fdgNoRoomForPicture:
    "The frame viewer has no room for a picture — " & remedyFor(gap) & "."

func degradedMessageFor*(state: PaneDegradation; gap: FrameDrawGap): string =
  ## §14's row, as the one line the pane prints.
  ##
  ## `app/source_binding.degradedMessageFor`'s shape: only the rows this pane
  ## OWNS produce text, because a frame viewer that printed "no verified
  ## source" would be reinventing §14's canonical treatment, which is the thing
  ## §14 exists to prevent. The three session-level rows are the debug-control
  ## pane's banner and are deliberately silent here.
  if state == pdDependencyMissing: describeFrameGap(gap)
  else: ""

proc historyRowsFrom*(entries: seq[VisualReplayPixelHistoryEntry]):
    seq[PixelHistoryRow] =
  ## §6.1's entries as the pane's rows.
  ##
  ## The four test columns are read from `testStatus` — the backend's own
  ## strings — rather than re-derived from `passed`, because `passed` is the
  ## AND of them and a row that showed four "pass" columns beside a failing
  ## status would be a rendering of a boolean pretending to be a table.
  ## An entry whose backend sent no status for a test prints `-`, which is
  ## distinguishable from `pass` and from `fail`.
  result = @[]
  for e in entries:
    func orDash(s: string): string = (if s.len > 0: s else: "-")
    result.add PixelHistoryRow(
      drawCallIndex: e.drawCallIndex,
      name: (if e.failureReason.len > 0 and not e.passed:
               "draw " & $e.drawCallIndex & " (" & e.failureReason & ")"
             else: "draw " & $e.drawCallIndex),
      passed: e.passed,
      depth: orDash(e.testStatus.depth),
      stencil: orDash(e.testStatus.stencil),
      blend: orDash(e.testStatus.blend),
      cull: orDash(e.testStatus.cull),
      path: "", line: 0)

proc nameDrawCalls*(rows: var seq[PixelHistoryRow];
                    calls: seq[VisualReplayDrawCall]) =
  ## Give each history row the DRAW CALL's own name, where the frame viewer
  ## has one for it.
  ##
  ## Separate from `historyRowsFrom` because the two lists come from two
  ## requests — `/pixel-history` and `/draw-calls` — and a row must render with
  ## whichever of them has arrived. A history that waited for the draw-call
  ## list would show nothing while the data it is about is already in hand.
  for row in rows.mitems:
    for call in calls:
      if call.index == row.drawCallIndex and call.name.len > 0:
        row.name = call.name
        break

proc frameViewerModelFor*(frames: FrameViewerVM;
                          history: PixelHistoryVM;
                          capability: ImageCapability;
                          core: DegradedStateSnapshot;
                          open = true;
                          raster = RgbaImage();
                          hasRaster = false;
                          encodedBytes = 0;
                          magnified = false;
                          magnifier = Magnifier();
                          pictureCols = 0;
                          pictureRows = 0): FrameViewerModel =
  ## The pane's model for the CURRENT frame.
  ##
  ## Everything is read at call time and nothing is retained: the returned
  ## value is a snapshot, exactly as `source_binding.sourcePaneModelFor`'s is,
  ## so a host that keeps one across a seek is holding a picture of a tick that
  ## has passed rather than a live handle to one that has not.
  ##
  ## `pictureCols`/`pictureRows` are the rectangle the caller will paint into,
  ## in **TERMINAL CELLS**, and they are parameters because the gap depends on
  ## them (`fdgNoRoomForPicture`) and this layer cannot see a terminal. A
  ## caller that passes zeros gets the gap that says so, which is the safe
  ## direction.
  result = initFrameViewerModel()
  result.open = open
  result.capability = capability
  result.raster = raster
  result.hasRaster = hasRaster
  result.encodedBytes = encodedBytes
  result.magnified = magnified
  result.magnifier = magnifier
  if not frames.isNil:
    result.frameIndex = frames.currentFrame.val
    result.frameCount = frames.frameCount.val
    result.sourceWidth = frames.frameWidth.val
    result.sourceHeight = frames.frameHeight.val
    result.drawCalls = frames.drawCalls.val.len
    result.selectedDrawCall =
      if frames.selectedDrawCall.val.isSome: frames.selectedDrawCall.val.get
      else: -1
    if not hasRaster and encodedBytes == 0 and
       frames.frameImageSrc.val.len > 0:
      # THE ENCODED FRAME'S LENGTH, IN BYTES, from the only thing the ViewModel
      # layer has: a `src` string. It is a LENGTH and not the bytes, and the
      # distinction is the one `emit.nim`'s header insists on — a tier-0
      # emission needs the payload, and `emitFrameViewerPicture` refuses rather
      # than pretending a length is one.
      result.encodedBytes = frames.frameImageSrc.val.len
  if not history.isNil:
    result.history = historyRowsFrom(history.entries.val)
    if not frames.isNil:
      result.history.nameDrawCalls(frames.drawCalls.val)
    if history.selectedEntry.val.isSome:
      result.selectedDrawCall = history.selectedEntry.val.get
    if history.selectedPixel.val.isSome:
      let p = history.selectedPixel.val.get
      result.historyPixelX = p.x
      result.historyPixelY = p.y
      result.historyRequested = true
  result.gap = result.resolveGap(pictureCols, pictureRows)
  result.degradedMessage = degradedMessageFor(
    frameViewerDegradation(core, result.gap), result.gap)

proc openMagnifierAt*(model: FrameViewerModel; col, row: int;
                      viewCols, viewRows: int): FrameViewerModel =
  ## §5's two stages, joined at the pane: a CELL the user moved a cursor to,
  ## opened into a magnifier over the source pixels that cell shows.
  ##
  ## RAISES when the model has no raster, and that is deliberate rather than
  ## defensive: a magnifier over a frame nobody decoded would report a
  ## coordinate into an image this process does not have, which is the guess §5
  ## forbids wearing a fallback's clothes. The caller asks `resolveGap` first,
  ## exactly as it does before painting.
  if not model.hasRaster:
    raise newException(MagnifierError,
      "there is no decoded frame to magnify: " & remedyFor(fdgNoDecoder))
  let fit = fitToCells(model.sourceWidth, model.sourceHeight,
                       DefaultCellAspect, viewCols, viewRows)
  result = model
  result.magnified = true
  result.magnifier = openMagnifier(model.sourceWidth, model.sourceHeight, fit,
                                   model.capability.tier, col, row,
                                   viewCols, viewRows)

proc moveCursorBy*(model: FrameViewerModel; dx, dy: int): FrameViewerModel =
  ## Move §5's PIXEL cursor by `(dx, dy)` **SOURCE PIXELS**.
  ##
  ## A no-op when no magnifier is open, rather than an implicit open: a key
  ## that moved a cursor into existence would make "the coordinate came from
  ## the magnification step" depend on which key was pressed first.
  if not model.magnified:
    return model
  result = model
  result.magnifier = model.magnifier.moveCursor(dx, dy)

proc requestPixelHistory*(history: PixelHistoryVM;
                          model: FrameViewerModel): bool =
  ## §5's last sentence: *"The magnifier reports the exact pixel coordinate,
  ## and that is what `pixel_history_vm` receives."*
  ##
  ## THE COORDINATE COMES FROM THE MAGNIFIER AND FROM NOWHERE ELSE. There is no
  ## overload of this that takes a cell, and that absence is the enforcement:
  ## §5's "the coordinate is never inferred from a cell position without the
  ## magnification step" cannot be violated by a caller who has no function to
  ## violate it with. Answers `false` when no magnifier is open, so a caller
  ## that skipped the second stage gets a refusal rather than a request about a
  ## pixel nobody picked.
  if history.isNil or not model.magnified:
    return false
  let (x, y) = model.magnifier.pickedPixel()
  history.loadPixelHistory(x, y, model.frameIndex)
  true

proc jumpToDrawCallSource*(history: PixelHistoryVM; index: int): bool =
  ## §6.1: *"Selecting an entry navigates the source pane to the draw call's
  ## location."*
  ##
  ## Forwards to `PixelHistoryVM.jumpToSourceForEntry`, which is the ViewModel's
  ## own published entry point for it and already carries the M6 contract
  ## (`ct/seek-to-geid`, resolved to a `Location`, emitted as
  ## `ct/complete-move`). A second navigation path in the terminal would be a
  ## second answer to "where does this draw call come from".
  if history.isNil:
    return false
  history.jumpToSourceForEntry(index)
