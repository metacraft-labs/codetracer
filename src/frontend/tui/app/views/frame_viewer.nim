## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/frame_viewer.nim — PLAT-15 deliverables 1, 3 and 4.
## `CodeTracer-TUI-Graphics.md` §4 (the frame viewer), §5 (the magnifier) and
## §6.1 (pixel history).
##
## ## THIS IS THE CALLER PLAT-14 DID NOT HAVE
##
## PLAT-14's bound 5 reads: *"NOTHING IS WIRED INTO A PANE. The tiers render,
## the emitter emits, the capability resolves and the media set widens, and no
## pane in `src/frontend/tui/app/views/` calls any of it."* This module is a
## pane in that directory and it calls all of it — `cell_render.renderCells`
## for the picture, `magnifier.renderMagnifier` for §5's overlay,
## `emit.emitCellImage` for the bytes, and `ImageCapability` for the tier and
## the reason. Every rule those modules encode acquires a real caller here for
## the first time, which is why three of PLAT-14's "unreachable" residues are
## reachable now and are handled rather than inherited (see `FrameDrawGap`).
##
## ## THIS PANE PAINTS CELLS, AND TIER 0 IS NOT CELLS
##
## `paintFrameViewer` composes a `StyledGrid` the compositor owns, so the only
## picture it can draw is a `cell_render.CellGrid`. A tier-0 frame is not one:
## it is an escape payload the terminal decodes, emitted out of band by
## `emit.emitProtocolImage` from the ENCODED bytes — which this model carries as
## a LENGTH and not as bytes, and which no host in this build sends (bound 1).
##
## So the resolved tier being `itProtocol` is a REPORTABLE CONDITION of this
## pane and not a picture: `fdgProtocolNotPainted`. **PLAT-15's landing pass is
## why that gap exists.** Before it, `resolveGap` asked `tiers.DrawableTiers`,
## which CONTAINS `itProtocol`, answered `fdgNone` for a Kitty terminal, and
## `renderCells` — which refuses tier 0 by name — raised out of
## `shellScreen`'s whole paint. The pane now asks `tiers.CellRenderableTiers`,
## the set the renderer itself gates on, so the pre-check and the refusal are
## one predicate (Verification-Harness-Traps §14).
##
## ## A PURE FUNCTION OF A VALUE, for the same three reasons every pane here is
##
## `FrameViewerModel` in, `FrameViewerScreen` out.
## `app/frame_viewer_binding.nim` is the only module that knows a ViewModel
## exists, and it is also the only module that names a `PaneDegradation` — the
## same split `app/views/source_pane.nim` and `app/source_binding.nim` make,
## where the view carries `degradedMessage` as text and the binding is what
## resolved §14's row into it.
##
## ## §2.6: DEGRADING NEVER BLANKS THE PANE
##
## *"Degradation never removes information … Where a feature genuinely cannot
## be shown at a tier, the pane says so rather than appearing to work."*
##
## So a `FrameDrawGap` replaces the PICTURE REGION and nothing else. The title
## still names the frame, its size in source pixels and the resolved tier; the
## pixel-history rows still render; the magnifier's reported coordinate still
## prints. `FrameViewerScreen.pictureRows` and `.historyRows` are counted
## separately for exactly this reason — a test can assert that the picture went
## to zero and the rest did not, which a single row count cannot say.
##
## ## THE TIER IS IN THE TITLE, AND SO IS THE REFUSAL
##
## §4: *"The pane declares its tier in its title, because a user needs to know
## whether they are looking at a faithful frame or a 2x3 approximation before
## they trust it."* `ImageCapability.describe` is that string and it is not
## re-derived here: it already names the tier, where the tier came from, the
## protocol, the multiplexer, the link budget and the refusal, and a second
## spelling in a pane would be a second thing to keep true.
##
## ## COLOURS ARE `#RRGGBB` AND THE LADDER QUANTISES THEM
##
## A rendered cell carries an exact `Rgb`, so the span it becomes carries the
## 24-bit spelling. `app/theme/degradation.projectStyle` is what puts it on the
## rung the terminal actually has — 256 colours, sixteen, or monochrome — and
## doing it here instead would be a second quantiser beside the one CTUI-11
## already asserts.

import isonim_tui

import ../../../../common/terminal_graphics
import ../layout/profile
import ../theme/image_capability
import ./styled_row

export styled_row, terminal_graphics, image_capability, profile

type
  FrameDrawGap* = enum
    ## WHY THE PICTURE REGION HAS NO PICTURE. `fdgNone` when it has one.
    ##
    ## Four of the five values are PLAT-14 residues, or this pane's own
    ## structure, that became reachable the moment a pane called it, and each is
    ## named here rather than discovered as an exception at draw time.
    fdgNone = "none"
    fdgPlayerAbsent = "player-absent"
      ## No reconstructed frame: `ct-gfx-player` is not connected, or this
      ## recording carries no graphics events. The ONE gap with an
      ## install-shaped remedy, which is why the binding maps it to `pdsAbsent`
      ## and the other three to `pdsUnsupported`.
    fdgNoDecoder = "no-decoder"
      ## PLAT-14 BOUND 3, ARRIVING AT A USER. The frame came back as an ENCODED
      ## image and the resolved tier is a CELL tier, which consumes a raster —
      ## and this build has no PNG or JPEG decoder. Tier 0 is unaffected:
      ## Kitty's `f=100` and iTerm2's `File=inline` decode in the terminal.
    fdgTierNotDrawable = "tier-not-drawable"
      ## PLAT-14 RESIDUE 3, ARRIVING AT A USER. `--image-tier=octant` parses and
      ## resolves, and PLAT-14 recorded that "a pane that pins it will meet a
      ## `CellRenderError` rather than a refusal it can report". This is the
      ## refusal it can report: the pane asks `tiers.CellRenderableTiers` BEFORE
      ## it paints, so the exception is never reached and the message names the
      ## two tiers that are.
    fdgProtocolNotPainted = "protocol-not-painted"
      ## THE RESOLVED TIER IS 0, AND THIS PANE PAINTS CELLS. See the module
      ## header. A tier-0 frame is bytes for the terminal to decode — Kitty's
      ## `f=100`, iTerm2's `File=inline` — emitted by `emit.emitProtocolImage`
      ## from the encoded payload, and it never becomes a `CellGrid`, so
      ## `paintFrameViewer` has no picture to put in the region.
      ##
      ## **IT IS THE ONLY GAP THAT IS NOT A DEGRADATION OF THE TERMINAL'S
      ## ABILITY.** The terminal can draw the frame better than any cell tier;
      ## what is missing is a host in this build that sends the payload (bound
      ## 1). The remedy is therefore a tier flag rather than an install, which
      ## is why the binding maps it to `pdsUnsupported` with the other two.
      ##
      ## A SUBSTITUTION WAS THE ALTERNATIVE AND IS REFUSED. The pane could paint
      ## `magnifier.magnifierTier(itProtocol)` — half blocks — the way §5's
      ## overlay does. §5's substitution is exact (at one or more whole cells
      ## per source pixel a half block's two samples are inside ONE source
      ## pixel); this one would not be, at any fit that down-samples. It would
      ## put a 1x2-sample approximation on screen under a title that reads
      ## `image-tier=protocol`, which is precisely the untrustworthy screen §4's
      ## sentence exists to prevent, and §2.6's "the pane says so rather than
      ## appearing to work" decides it.
    fdgNoRoomForPicture = "no-room"
      ## The rectangle left after the title, the magnifier header and the
      ## pixel-history rows is too small to carry a cell rendering. A reported
      ## condition rather than a blank region, on PLAT-12's rule that a bound
      ## reached is "a reportable condition carrying the rule to edit — never a
      ## blank region".

  PixelHistoryRow* = object
    ## §6.1's "list with a status column and a source location", as a value.
    ## The shape `app/views/call_stack.nim` renders, with pass/fail in place of
    ## a frame index and the four tests §6.1 names as the columns.
    drawCallIndex*: int
    name*: string
    passed*: bool
    depth*: string
    stencil*: string
    blend*: string
    cull*: string
    path*: string
    line*: int

  FrameViewerModel* = object
    ## Everything the pane shows, as a value.
    open*: bool
      ## CLOSED BY DEFAULT, which is what keeps every screen this repository
      ## has a golden for byte-identical: `views/shell.nim` paints the overlay
      ## only when this is true, exactly as it paints the tracepoint dialog
      ## only when that one is open.
    frameIndex*: int
    frameCount*: int
    sourceWidth*: int
    sourceHeight*: int
      ## The reconstructed frame's extent, in **SOURCE PIXELS**.
    raster*: RgbaImage
      ## The frame's pixels, when there are any. `hasRaster` says whether there
      ## are: an `RgbaImage` cannot be empty (`initRgbaImage` refuses a
      ## zero extent), so a default-constructed one is 0x0 and unusable.
    hasRaster*: bool
    encodedBytes*: int
      ## The encoded payload's length in **BYTES**, for a tier-0 emission and
      ## for the link-budget decision. Zero when the frame arrived as a raster.
    capability*: ImageCapability
      ## What `app/theme/image_capability.resolveImageCapability` settled on.
      ## The tier, the protocol, the refusal, the multiplexer, the link budget
      ## — one value, carried rather than decomposed, so `describe` is the
      ## title and not a re-derivation of it.
    gap*: FrameDrawGap
    degradedMessage*: string
      ## What the BINDING resolved `gap` into: §8.2's "what is missing and how
      ## to get it". Text here for `source_pane.degradedMessage`'s reason — the
      ## view renders §14's row, it does not decide one.
    magnified*: bool
    magnifier*: Magnifier
      ## §5's second stage. Meaningless unless `magnified`.
    drawCalls*: int
    selectedDrawCall*: int
    history*: seq[PixelHistoryRow]
    historyPixelX*: int
    historyPixelY*: int
      ## The **SOURCE PIXEL** the history below was requested for. Carried
      ## separately from `magnifier.cursorX/cursorY` on purpose: the cursor is
      ## where the user is NOW and this is what the list on screen is ABOUT,
      ## and a pane that printed one for the other would label a stale list
      ## with a live coordinate.
    historyRequested*: bool

  FrameViewerScreen* = object
    ## One painted overlay, plus the counts a test asserts on.
    rows*: seq[StyledRow]
    area*: CellArea
    pictureRows*: int
      ## Rows of CELL RENDERING (or of magnifier) actually painted. Zero when
      ## the pane degraded — and the §2.6 assertion is that this is zero while
      ## `historyRows` and the title are not.
    pictureCols*: int
    historyRows*: int
    degradedRows*: int
    tierDrawn*: ImageTier
      ## The tier the picture was ACTUALLY drawn at, which is
      ## `magnifier.magnifierTier(capability.tier)` while magnified and
      ## `capability.tier` otherwise. Reported rather than inferred, because
      ## §4's "declares its tier" is a claim about what a user is looking at.
    candidatesEvaluated*: int
      ## The only WORK quantity this pane claims: candidate masks the per-cell
      ## argmin evaluated, summed over the picture. An EQUALITY against
      ## `tiers.candidatesPerCell` times the cell count is assertable, and it is
      ## identical on every build and memory manager — so no timing is claimed
      ## anywhere in this module (Verification-Harness-Traps §12b).

const
  FrameViewerTitle* = "FRAME VIEWER"
  PixelHistoryTitle* = "PIXEL HISTORY"
  TitleStyle* = CellStyle(fg: "white", bold: true)
  MutedStyle* = CellStyle(fg: "bright_black")
  DegradedStyle* = CellStyle(fg: "red", bold: true)
  PassStyle* = CellStyle(fg: "green")
  FailStyle* = CellStyle(fg: "red", bold: true)
  SelectedStyle* = CellStyle(fg: "white", bold: true, reverse: true)
  PassGlyph* = "+"
  FailGlyph* = "x"
    ## ASCII, deliberately. §2.5's tier exists for `TERM=dumb` and a CI log,
    ## and a pass/fail column that needed a Unicode tick would be the one
    ## column of this pane that vanished on the terminal the ASCII tier is for.
  CursorStyleOverlay* = CellStyle(reverse: true)
    ## §2.6: "It never silently omits an overlay, a selection marker or a
    ## magnifier cursor."
    ##
    ## `reverse` AND NOT A COLOUR, because `reverse` is the one attribute that
    ## survives every rung of CTUI-11's ladder including monochrome — see
    ## `app/theme/degradation.projectStyle`, whose `cdMonochrome` arm turns a
    ## background into exactly this. A coloured cursor would be invisible on a
    ## `TERM=dumb` terminal, which is the tier the cursor matters most on
    ## because the picture there is already coarse.
    ##
    ## AND THE COORDINATE IS PRINTED AS TEXT BESIDE IT. A highlight can be lost
    ## to a terminal that ignores `reverse`; `describeMagnifier`'s line cannot.

func rgbSpelling*(c: Rgb): string =
  ## A rendered colour as the `#RRGGBB` spelling `isonim_tui`'s compositor and
  ## `app/theme/degradation` both understand.
  ##
  ## The 24-bit rung is written here and quantised there, never the other way
  ## round: a pane that emitted `indexed:N` would have made the decision
  ## CTUI-11's ladder makes, one layer too early and with no terminal in scope.
  const Digits = "0123456789abcdef"
  result = "#"
  for v in [c.r, c.g, c.b]:
    result.add Digits[int(v) shr 4]
    result.add Digits[int(v) and 0xF]

func initFrameViewerModel*(): FrameViewerModel =
  ## The CLOSED pane. Named rather than relying on zero-initialisation, for
  ## `store/degraded_state.initDegradedStateSnapshot`'s reason: reordering a
  ## field must not silently change what "no frame viewer" means.
  FrameViewerModel(open: false, frameIndex: 0, frameCount: 0,
                   gap: fdgNone, magnified: false, history: @[],
                   selectedDrawCall: -1, historyRequested: false)

func isEmpty*(model: FrameViewerModel): bool =
  ## Whether the shell should leave the body alone. Closed IS empty.
  not model.open

func drawableTierFor*(model: FrameViewerModel): ImageTier =
  ## The tier the PICTURE is drawn at, which is not always the tier the
  ## capability resolved to: §5's overlay renders at a cell tier even on a
  ## tier-0 terminal (`magnifier.magnifierTier`, whose header says why).
  if model.magnified: magnifierTier(model.capability.tier)
  else: model.capability.tier

func resolveGap*(model: FrameViewerModel; pictureCols, pictureRows: int):
    FrameDrawGap =
  ## WHY THIS PANE CANNOT DRAW, or `fdgNone`.
  ##
  ## ONE PREDICATE, and the binding calls this same function rather than
  ## re-deciding (Verification-Harness-Traps §14): the pane needs the answer to
  ## lay out its rectangle and the binding needs it to resolve a
  ## `PaneDegradation`, and two spellings of "can this draw?" is two things
  ## that can disagree while each agrees with itself.
  ##
  ## The ORDER is most-fundamental-first, on `resolveDegradation`'s own rule:
  ## a pane with no frame at all has a more basic problem than a pane whose
  ## tier has no glyph table, and telling a user to change `--image-tier` when
  ## no player is connected would be the instruction that does not help.
  if not model.hasRaster and model.encodedBytes == 0:
    return fdgPlayerAbsent
  let tier = model.drawableTierFor()
  if tier notin CellRenderableTiers:
    # THE SET THE RENDERER ITSELF GATES ON, and not `DrawableTiers` — which
    # contains `itProtocol`, the one tier `cell_render.renderCells` refuses, so
    # asking it here answered "you may paint this" for a Kitty terminal and the
    # exception escaped the shell (§14; the module header carries the
    # measurement). ONE predicate, asked once, with the two non-members
    # distinguished by REASON: an octant has no glyph table anywhere, and tier 0
    # has no cells to have a table for.
    return
      if tier == itProtocol: fdgProtocolNotPainted
      else: fdgTierNotDrawable
  if not model.hasRaster:
    # PLAT-14 bound 3. An ENCODED frame on a terminal that must render cells.
    # No `tier != itProtocol` guard any more: tier 0 has already returned above,
    # so every tier that reaches this line consumes a raster. The old
    # conjunction was the second half of the same defect — it let tier 0 past
    # the decoder question too, and there was nothing after it that could stop
    # a zero raster reaching `renderCells`.
    return fdgNoDecoder
  if pictureCols <= 0 or pictureRows <= 0:
    return fdgNoRoomForPicture
  fdgNone

func remedyFor*(gap: FrameDrawGap): string =
  ## §8.2's "how to get it", per gap. The ONE place a remedy is written, so the
  ## pane's message and the binding's `PaneDegradation` detail are one string.
  case gap
  of fdgNone: ""
  of fdgPlayerAbsent:
    "start ct-gfx-player for this recording, or open a recording that carries " &
    "graphics events"
  of fdgNoDecoder:
    # THIS REMEDY WAS STALE THE MOMENT `fdgProtocolNotPainted` EXISTED. It used
    # to end "use a Kitty or iTerm2 terminal, or --image-tier=protocol where the
    # path allows it", which sent a user to the tier this pane now reports it
    # cannot paint — a remedy naming a route that answers a different refusal is
    # the instruction that does not help, and it is the neighbour a repair
    # leaves behind (Verification-Harness-Traps §15).
    "this build has no PNG or JPEG decoder, so a cell tier cannot draw an " &
    "encoded frame, and no --image-tier flag changes that: a Kitty or iTerm2 " &
    "terminal decodes tier 0 in the TERMINAL, which is the route out, and " &
    "this pane does not transmit one yet (see protocol-not-painted)"
  of fdgTierNotDrawable:
    "image tier 'octant' (U+1CD00) has no verified glyph table in this build; " &
    "pick --image-tier=sextant for 2x3 or --image-tier=braille for 2x4"
  of fdgProtocolNotPainted:
    # THE ACTION FIRST, unlike the two remedies above, and for a measured
    # reason: this is the only remedy whose actionable half is a FLAG rather
    # than a sentence, and the pane truncates a remedy to the overlay's width —
    # at 70 columns the explanation alone fills the row and the flag falls off
    # the end, which is a remedy that cannot be acted on.
    "pick --image-tier=half-block (or another cell tier) to draw this frame " &
    "as cells here: a tier-0 frame is TRANSMITTED to the terminal as a " &
    "graphics payload, not painted as cells, and nothing in this build sends " &
    "one from this pane"
  of fdgNoRoomForPicture:
    "give the pane more rows, or close the pixel-history list"

proc titleText*(model: FrameViewerModel): string =
  ## §4's title row: what frame, how big, and AT WHICH TIER.
  ##
  ## The tier string is `ImageCapability.describe` verbatim — the same line
  ## every failure message in the image path quotes — so a user comparing a
  ## pane title with a `--image-tier` refusal is reading one sentence and not
  ## two renderings of it.
  result = FrameViewerTitle
  if model.frameCount > 0:
    result.add "  frame " & $model.frameIndex & "/" & $model.frameCount
  else:
    result.add "  frame " & $model.frameIndex
  if model.sourceWidth > 0 and model.sourceHeight > 0:
    result.add "  " & $model.sourceWidth & "x" & $model.sourceHeight & "px"
  result.add "  " & describe(model.capability)
  if model.magnified:
    # THE OVERLAY'S OWN TIER, when it differs from the frame's. Without this a
    # user magnifying on a Kitty terminal would read `image-tier=protocol` in a
    # title above a half-block picture, which is exactly the untrustworthy
    # screen §4's sentence exists to prevent.
    let drawn = model.drawableTierFor()
    if drawn != model.capability.tier:
      result.add "  magnifier=" & tierName(drawn)

proc historyTitleText*(model: FrameViewerModel): string =
  ## §6.1's list header, naming the **SOURCE PIXEL** the list is about.
  result = PixelHistoryTitle
  if model.historyRequested:
    result.add "  pixel " & $model.historyPixelX & "," & $model.historyPixelY
  else:
    result.add "  no pixel picked"
  result.add "  " & $model.history.len & " draw call(s)"
  if model.drawCalls > 0:
    result.add " of " & $model.drawCalls

proc historyRowSpans*(row: PixelHistoryRow; selected: bool;
                      width: int): StyledRow =
  ## One §6.1 row: `#3 + draw_quad  d:pass s:pass b:pass c:pass  scene.c:114`.
  ##
  ## The four test columns are §6.1's own — "pass/fail for depth, stencil,
  ## blend and cull" — and they are printed even when they all pass, because a
  ## row that only showed the failing test would make "this draw call touched
  ## the pixel and passed everything" indistinguishable from "this row has no
  ## test data".
  result = @[]
  if width <= 0:
    return
  let statusStyle = if row.passed: PassStyle else: FailStyle
  let nameStyle = if selected: SelectedStyle else: DefaultCellStyle
  var parts: seq[StyledSpan] = @[]
  parts.add StyledSpan(text: "#" & $row.drawCallIndex & " ", style: MutedStyle)
  parts.add StyledSpan(text: (if row.passed: PassGlyph else: FailGlyph),
                       style: statusStyle)
  parts.add StyledSpan(text: " " & row.name, style: nameStyle)
  parts.add StyledSpan(
    text: "  d:" & row.depth & " s:" & row.stencil & " b:" & row.blend &
          " c:" & row.cull,
    style: MutedStyle)
  if row.path.len > 0:
    parts.add StyledSpan(text: "  " & pathBaseName(row.path) & ":" & $row.line,
                         style: MutedStyle)
  var used = 0
  for part in parts:
    if used >= width:
      break
    let fitted = truncateToCells(part.text, width - used)
    if fitted.len == 0:
      continue
    result.add StyledSpan(text: fitted, style: part.style)
    used += cellWidthOf(fitted)

proc gridRowSpans*(grid: CellGrid; row: int; width: int;
                   cursorCol = -1; cursorRow = -1;
                   cursorCols = 0; cursorRows = 0): StyledRow =
  ## One row of a rendered picture, as styled spans.
  ##
  ## The cursor block is `cursorCols x cursorRows` CELLS at `(cursorCol,
  ## cursorRow)`, which is one SOURCE PIXEL at the magnifier's zoom — see
  ## `magnifier.cursorCell`. Passing the block rather than a single cell is
  ## what keeps the marker over the whole pixel: a cursor drawn on one cell of
  ## a 2x1-cell pixel would be a half-pixel highlight, which says something
  ## about a coordinate that is not true.
  result = @[]
  if width <= 0 or row < 0 or row >= grid.rows:
    return
  var col = 0
  while col < grid.cols and col < width:
    let cell = grid.cellAt(col, row)
    var style = CellStyle(fg: rgbSpelling(cell.fg))
    if grid.tier != itAscii:
      # §2.5's ramp carries its picture in the GLYPH and `renderCells` leaves
      # an ASCII cell's `bg` at the zero `Rgb` — "no opinion", not black.
      # Painting it would put a black rectangle over the user's own terminal
      # background at every cell, which is the DIFFERENT picture PLAT-14's M32
      # arm exists to keep out of the emitter. The same rule, one layer up.
      style.bg = rgbSpelling(cell.bg)
    if cursorCols > 0 and cursorRows > 0 and
       col >= cursorCol and col < cursorCol + cursorCols and
       row >= cursorRow and row < cursorRow + cursorRows:
      style.reverse = true
    result.add StyledSpan(text: cell.glyph, style: style)
    inc col

proc paintFrameViewer*(g: var StyledGrid; area: CellArea;
                       model: FrameViewerModel): FrameViewerScreen =
  ## Paint the overlay into `area` of `g`, and report what it painted.
  ##
  ## The layout, top to bottom: the title row, the picture (or the report that
  ## replaces it), the magnifier's coordinate line when magnified, the
  ## pixel-history title and its rows. THE TITLE AND THE HISTORY ARE PAINTED
  ## WHETHER OR NOT THE PICTURE IS, which is §2.6 as control flow rather than
  ## as a comment.
  result = FrameViewerScreen(rows: @[], area: area, pictureRows: 0,
                             pictureCols: 0, historyRows: 0, degradedRows: 0,
                             tierDrawn: model.drawableTierFor(),
                             candidatesEvaluated: 0)
  if area.width <= 0 or area.height <= 0:
    return

  g.paint(area.row, area.col, truncateToCells(model.titleText(), area.width),
          TitleStyle)
  if area.height <= 1:
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  # ---- how the rows are divided ------------------------------------------
  #
  # The history list is given what it asks for up to half the body, and the
  # picture takes the rest. The history is bounded FIRST because §6.2's point
  # is that "pixel history is mostly text" — but a list that took the whole
  # pane would leave no picture to pick a pixel WITH, which is the one thing
  # the terminal front-end cannot do without.
  let body = area.height - 1
  let magnifierLine = if model.magnified: 1 else: 0
  let wantHistory =
    if model.history.len > 0 or model.historyRequested: model.history.len + 1
    else: 0
  let historyHeight = max(0, min(wantHistory, body div 2))
  let pictureHeight = max(0, body - historyHeight - magnifierLine)
  let gap = model.resolveGap(area.width, pictureHeight)

  var atRow = area.row + 1

  if gap == fdgNone:
    let tier = model.drawableTierFor()
    let grid =
      if model.magnified:
        renderMagnifier(model.raster, model.magnifier, model.capability.tier)
      else:
        # THE ASPECT IS `DefaultCellAspect`, NAMED AT THE CALL SITE. Nothing in
        # this build sends `CSI 16 t` (PLAT-14 bound 9), so `casReported` has
        # no producer and every shipped rendering corrects against 1:2 — and
        # this is the call site that would change on the day one appears.
        renderCells(model.raster, tier,
                    fitToCells(model.sourceWidth, model.sourceHeight,
                               DefaultCellAspect, area.width, pictureHeight))
    result.candidatesEvaluated = grid.candidatesEvaluated
    result.pictureCols = min(grid.cols, area.width)
    var cursorCol = -1
    var cursorRow = -1
    var cursorCols = 0
    var cursorRows = 0
    if model.magnified:
      let (cc, cr) = model.magnifier.cursorCell()
      cursorCol = cc
      cursorRow = cr
      cursorCols = model.magnifier.zoomCols
      cursorRows = model.magnifier.zoomRows
    for r in 0 ..< min(grid.rows, pictureHeight):
      var at = area.col
      for span in gridRowSpans(grid, r, area.width, cursorCol, cursorRow,
                               cursorCols, cursorRows):
        g.paint(atRow, at, span.text, span.style)
        at += cellWidthOf(span.text)
      inc atRow
      inc result.pictureRows
  else:
    # THE PICTURE REGION SAYS WHY, AND THE PANE KEEPS GOING. Two rows at most:
    # what is missing, and how to get it. `degradedMessage` is what the binding
    # resolved §14's row into; `remedyFor` is the same string the binding's
    # detail quotes, so the pane and the report cannot come to differ.
    let message =
      if model.degradedMessage.len > 0: model.degradedMessage
      else: "this frame cannot be drawn here (" & $gap & ")"
    if pictureHeight >= 1:
      g.paint(atRow, area.col, truncateToCells(message, area.width),
              DegradedStyle)
      inc atRow
      inc result.degradedRows
    if pictureHeight >= 2:
      g.paint(atRow, area.col,
              truncateToCells(remedyFor(gap), area.width), MutedStyle)
      inc atRow
      inc result.degradedRows

  if model.magnified and atRow < area.row + area.height:
    # §5's reported coordinate, AS TEXT. The highlight above can be lost to a
    # terminal that ignores `reverse`; this line cannot, and it is the value
    # `pixel_history_vm` receives.
    g.paint(atRow, area.col,
            truncateToCells(describeMagnifier(model.magnifier), area.width),
            MutedStyle)
    inc atRow

  if historyHeight >= 1 and atRow < area.row + area.height:
    g.paint(atRow, area.col,
            truncateToCells(model.historyTitleText(), area.width), TitleStyle)
    inc atRow
    var shown = 0
    while shown < model.history.len and shown < historyHeight - 1 and
          atRow < area.row + area.height:
      var at = area.col
      for span in historyRowSpans(model.history[shown],
                                 shown == model.selectedDrawCall, area.width):
        g.paint(atRow, at, span.text, span.style)
        at += cellWidthOf(span.text)
      inc atRow
      inc shown
      inc result.historyRows

  for r in area.row ..< area.row + area.height:
    result.rows.add g.rowSpansIn(r, area.col, area.width)

proc frameViewerScreen*(model: FrameViewerModel;
                        width, height: int): FrameViewerScreen =
  ## The pane on a screen of its own — the shape a Tier-1 test uses, exactly as
  ## `call_stack.callStackScreen` is.
  var g = newStyledGrid(width, height)
  result = paintFrameViewer(
    g, CellArea(col: 0, row: 0, width: width, height: height), model)

proc frameViewerRows*(model: FrameViewerModel;
                      width, height: int): seq[StyledRow] =
  frameViewerScreen(model, width, height).rows

proc frameViewerText*(model: FrameViewerModel;
                      width, height: int): seq[string] =
  ## The pane as plain text, one string per row.
  result = @[]
  for row in frameViewerRows(model, width, height):
    result.add rowText(row)

proc emitFrameViewerPicture*(model: FrameViewerModel;
                             width, height: int;
                             writing = cwTrueColor): EmittedImage =
  ## THE BYTES, for the path that has them.
  ##
  ## §7's rule that a claim about what a terminal is told is a claim about a
  ## BYTE STRING, applied to this pane: `emit.emitCellImage`, for a CELL tier.
  ## **Tier 0's `emit.emitProtocolImage` is not called from here and cannot be**
  ## — it takes the encoded PAYLOAD and this model carries a length — which is
  ## exactly what `fdgProtocolNotPainted` reports. Nothing else in `app/`
  ## produces
  ## terminal bytes for an image, and the reason this exists beside the painter
  ## rather than inside it is that the painter's output is a `StyledGrid` the
  ## compositor owns — a tier-0 emission has no cells and cannot go through it.
  ##
  ## RAISES for a model that cannot draw, by the same rule
  ## `cell_render.glyphFor` raises: a caller must ask `resolveGap` first, and
  ## an emitter that answered an empty string for an undrawable model would
  ## make "nothing was emitted" and "this tier cannot draw" the same value.
  ##
  ## **ONE REFUSAL, FROM `resolveGap`.** An unmagnified tier-0 model used to be
  ## refused twice — once here, by a second `capability.tier == itProtocol`
  ## test, because `resolveGap` answered `fdgNone` for it. That answer was the
  ## PANE's defect (see the module header), and with it repaired the second test
  ## is unreachable: `fdgProtocolNotPainted` returns above, carrying the same
  ## fact in `remedyFor`'s one string. A guard no case can reach is a row that
  ## looks like coverage (Verification-Harness-Traps §16a), so it is gone rather
  ## than kept as defence in depth over a condition that cannot occur.
  let pictureHeight = max(0, height - 1)
  let gap = model.resolveGap(width, pictureHeight)
  if gap != fdgNone:
    raise newException(EmitError,
      "this frame viewer cannot draw (" & $gap & "): " & remedyFor(gap))
  let tier = model.drawableTierFor()
  let grid =
    if model.magnified:
      renderMagnifier(model.raster, model.magnifier, model.capability.tier)
    else:
      renderCells(model.raster, tier,
                  fitToCells(model.sourceWidth, model.sourceHeight,
                             DefaultCellAspect, width, pictureHeight))
  emitCellImage(grid, writing)
