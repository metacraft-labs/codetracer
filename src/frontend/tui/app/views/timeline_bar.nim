## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/timeline_bar.nim — CTUI-8. The scrubber of CodeTracer-TUI.md
## §3.3.5: the bounds `[` and `]`, the execution needle `▲`, the tracepoint and
## bookmark diamonds `◆`, and the recorded call spans `█`.
##
## ## THE QUANTIZATION IS A PURE FUNCTION AND IS TESTED AS ONE
##
## CTUI-8: "the scrubber maps ticks to columns by integer quantization; the
## mapping is a pure function tested independently of rendering", and its
## verification gate is "needle mapping correct at every tested width". So
## `columnForTick` takes four integers and returns one, touches nothing, and
## `app/tests/test_timeline_scrubber_quantization.nim` sweeps it over widths
## 20..200 and tick counts spanning five orders of magnitude without painting a
## cell. Off-by-one at the ends is the entire defect class here, which is why
## the two ends are assertions of their own rather than corollaries of
## monotonicity.
##
## The arithmetic is INTEGER and rounds half up:
##
##     column = ((tick - minTick) * (trackWidth - 1) + span div 2) div span
##
## Integer rather than `float`, because a float mapping's two ends are the two
## places rounding can put the needle one cell outside the track, and because
## the same expression has to be exact at a tick count no float32 could hold.
## The one place a float appears is the OVERFLOW GUARD below, and it names
## itself.
##
## `tickForColumn` is the inverse and is what §4.4's "clicking on the timeline
## scrubber seeks the execution pointer directly to the clicked time ratio"
## means as arithmetic. It is deliberately NOT required to round-trip exactly —
## a track of 78 cells cannot address 1314 ticks — but `columnForTick` of its
## answer is required to be the column that was clicked, which is the property
## that makes a click land where the user pointed. Both halves are asserted.
##
## ## WHAT HAS A REAL SOURCE HERE, AND WHAT DOES NOT
##
## Established by reading `src/frontend/viewmodel/` and by RUNNING the three
## fixtures of CTUI-1's corpus through a real `replay-server` on 2026-09-06.
## `app/timeline_binding.nim`'s header carries the measurements; the short form
## is the reason this model has a `boundsNote` and a `marksNote` at all:
##
##   * the BOUNDS are real, and they do not come from `TimelineVM`.
##     `TimelineVM.markers` is a memo over `store.timeline`, and nothing writes
##     `store.timeline` on a completed replay session — only the live-MCR
##     `updateRecordingHead` / `requestRestoreAt` paths do. Measured: `markers`
##     is `@[]` on all three fixtures, before and after stepping. The recording's
##     last tick arrives instead on every `ct/event-load` row as `maxRRTicks`
##     (171 / 1314 / 3896), which the engine builds from `last_step_id`.
##   * the SPANS are real: `ct/load-calltrace-section` answers rows carrying
##     `rrTicks` and `depth`, which is a recorded call and its nesting.
##   * the MARKS are USER-DEFINED and start empty. §3.3.5 calls them "user-
##     defined tracepoints and bookmarks"; there is no bookmark concept anywhere
##     in `src/frontend/viewmodel/` (grep, 2026-09-06: every hit is a browser
##     bookmark in the platform layer), so a bookmark can only be one the user
##     made in this session. A tracepoint mark is one the engine VERIFIED —
##     `app/views/tracepoint_manager.nim` composes the request and the engine
##     answers `verified: true` with the line it bound.
##
## A model with no bounds renders its REASON where the bar would be, rather than
## an empty track — an empty track and an unknown recording are different
## answers and only the second one is true.

import std/algorithm

import isonim_tui

import ../layout/profile
import ./styled_row

export styled_row, profile

type
  TimelineSpan* = object
    ## One recorded call, as the scrubber shows it: `[startTick, endTick]` and
    ## how deep it is nested.
    startTick*: uint64
    endTick*: uint64
    depth*: int
    name*: string

  TimelineMarkKind* = enum
    ## Why a `◆` is on the track. §3.3.5 names both in one bullet; they are
    ## distinguished here because only one of them has an engine behind it and
    ## a reader of a screenshot should be able to tell which.
    tmkTracepoint
    tmkBookmark

  TimelineMark* = object
    tick*: uint64
    kind*: TimelineMarkKind
    label*: string

  TimelineBarModel* = object
    ## Everything the scrubber shows, as a value.
    minTick*: uint64
    maxTick*: uint64
    currentTick*: uint64
    boundsKnown*: bool
      ## Whether `minTick`/`maxTick` came from the recording. FALSE renders
      ## `boundsNote` instead of a track: see this module's header.
    boundsNote*: string
    spans*: seq[TimelineSpan]
    marks*: seq[TimelineMark]
    marksNote*: string
      ## Why there are no marks, when there are none and a reason is known.
      ## Rendered in the title row, never in place of the track.

  TimelineBarScreen* = object
    ## One painted scrubber, plus every coordinate a test asserts on.
    rows*: seq[StyledRow]
    area*: CellArea
    barRow*: int
      ## SCREEN row the track is on, or -1 when the area was too short.
    trackCol*: int
      ## SCREEN column of track cell 0 — the cell just right of `[`.
    trackWidth*: int
    needleColumn*: int
      ## TRACK-RELATIVE column of `▲`, or -1 when there is no track.
    markColumns*: seq[int]
      ## Track-relative, ascending, DEDUPLICATED: two marks that quantize onto
      ## one cell are one diamond, and a pane that reported two would let a
      ## test count marks that are not on screen.
    spanColumns*: seq[int]
      ## Track-relative cells covered by at least one span, ascending.
    paintedMarks*: int
    paintedSpans*: int
      ## Cells actually carrying `◆` / `█` AFTER the needle has been drawn over
      ## them. The needle wins, so these are the counts on the SCREEN rather
      ## than the counts in the model.
    boundsColumns*: seq[int]
      ## The two screen columns holding `[` and `]`, in that order. Empty when
      ## the pane is too narrow for a track.

const
  TimelineTitle* = "TIMELINE"
    ## Contains the string CTUI-3's own pane title produced
    ## (`shell.paneTitle(paneTimeline)` uppercased), so every CTUI-3 assertion
    ## that reads `TIMELINE` off a shell row still reads it once this pane fills
    ## that rectangle.
  PaneRule* = "─"

  BoundsOpenGlyph* = "["
  BoundsCloseGlyph* = "]"
  TrackGlyph* = "─"
  NeedleGlyph* = "▲"
  MarkGlyph* = "◆"
  SpanGlyph* = "█"

  MinBarWidth* = 3
    ## `[`, one track cell, `]`. Below this there is no scrubber at all and the
    ## row is left blank rather than drawn with the ends touching.

  TimelineBarRows* = 2
    ## Rows this pane owns at the top of its rectangle: the title and the track.
    ## Named because the `paneTimeline` rectangle is SHARED — §3.3.5 is one pane
    ## holding a scrubber AND an event log — and `app/views/shell.nim` gives the
    ## rest to `app/views/event_log.nim`.

  TitleStyle* = CellStyle(fg: "white", bold: true)
  TitleDetailStyle* = CellStyle(fg: "bright_black")
  RuleStyle* = CellStyle(fg: "bright_black")
  BoundsStyle* = CellStyle(fg: "white", bold: true)
  TrackStyle* = CellStyle(fg: "bright_black")
  SpanStyle* = CellStyle(fg: "blue")
  MarkStyle* = CellStyle(fg: "yellow", bold: true)
  NeedleStyle* = CellStyle(fg: "bright_cyan", bold: true)
    ## Five glyphs, five distinguishable colours, all of them ANSI NAMES so both
    ## tiers report the same indexed value — 7, 8, 4, 3 and 14. Every one is
    ## asserted as a NUMBER in `tests/real_terminal/test_real_timeline.nim`,
    ## because `docs/tui-testing.md` is explicit that a differential check is
    ## blind to a defect both tiers share.

  UnknownBoundsText* = "no recorded bounds"
  UnknownBoundsStyle* = CellStyle(fg: "bright_black", italic: true)

# ---------------------------------------------------------------------------
# THE QUANTIZATION. Pure, integer, and the subject of its own suite.
# ---------------------------------------------------------------------------

func trackWidthFor*(paneWidth: int): int =
  ## Track cells available in a scrubber `paneWidth` cells wide. The two bounds
  ## glyphs are not part of the track: `[` is the recording's start MARKER, not
  ## its first tick, and a mapping that let the needle land on it would put the
  ## execution pointer outside the recording at tick 0.
  if paneWidth < MinBarWidth: 0 else: paneWidth - 2

func columnForTick*(tick, minTick, maxTick: uint64; trackWidth: int): int =
  ## The track cell `tick` falls in. See this module's header for the formula.
  ##
  ## Clamped at both ends rather than allowed out of range: a tick beyond the
  ## recording is a caller's bug, and a needle painted at column -1 would be a
  ## silent no-op while a needle painted at `trackWidth` would overwrite `]`.
  if trackWidth <= 0:
    return -1
  if trackWidth == 1 or maxTick <= minTick:
    return 0
  let clamped =
    if tick <= minTick: minTick
    elif tick >= maxTick: maxTick
    else: tick
  let delta = clamped - minTick
  let span = maxTick - minTick
  let steps = uint64(trackWidth - 1)
  # THE OVERFLOW GUARD, and the only float in this module. `delta * steps`
  # cannot be formed when `delta` is within a factor of `steps` of 2^64. No
  # recording in existence is that long, so this branch is unreachable from a
  # trace — it is here because the alternative to a guard is a wrap-around that
  # puts the needle at a plausible-looking wrong column.
  if delta > high(uint64) div steps:
    let ratio = float(delta) / float(span)
    return max(0, min(trackWidth - 1, int(ratio * float(steps) + 0.5)))
  int((delta * steps + span div 2) div span)

func tickForColumn*(column: int; minTick, maxTick: uint64;
                    trackWidth: int): uint64 =
  ## §4.4's "seeks the execution pointer directly to the clicked time ratio".
  ##
  ## The inverse of `columnForTick`, in the only sense an inverse of a
  ## many-to-one map can have: `columnForTick(tickForColumn(c)) == c` for every
  ## `c` on the track. That is the property a click needs and it is asserted;
  ## the other direction cannot hold and is not claimed.
  if trackWidth <= 0 or maxTick <= minTick:
    return minTick
  let c = max(0, min(trackWidth - 1, column))
  if trackWidth == 1 or c == 0:
    return minTick
  if c == trackWidth - 1:
    return maxTick
  let span = maxTick - minTick
  let steps = uint64(trackWidth - 1)
  if span > high(uint64) div uint64(c):
    let ratio = float(c) / float(steps)
    return minTick + uint64(float(span) * ratio + 0.5)
  minTick + (span * uint64(c) + steps div 2) div steps

func trackColumnsForSpan*(span: TimelineSpan; minTick, maxTick: uint64;
                          trackWidth: int): seq[int] =
  ## Every track cell `span` covers, ascending. A span shorter than one cell
  ## still covers ONE — a recorded call that lasted three ticks out of 1314 is
  ## still a call, and dropping it would make the busiest part of a recording
  ## the emptiest part of the bar.
  result = @[]
  if trackWidth <= 0:
    return
  let lo = columnForTick(min(span.startTick, span.endTick), minTick, maxTick,
                         trackWidth)
  let hi = columnForTick(max(span.startTick, span.endTick), minTick, maxTick,
                         trackWidth)
  if lo < 0 or hi < 0:
    return
  for c in lo .. hi:
    result.add c

# ---------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------

proc initTimelineBarModel*(minTick = 0'u64; maxTick = 0'u64;
                           currentTick = 0'u64;
                           boundsKnown = false; boundsNote = "";
                           spans: seq[TimelineSpan] = @[];
                           marks: seq[TimelineMark] = @[];
                           marksNote = ""): TimelineBarModel =
  TimelineBarModel(
    minTick: minTick, maxTick: maxTick, currentTick: currentTick,
    boundsKnown: boundsKnown, boundsNote: boundsNote,
    spans: spans, marks: marks, marksNote: marksNote)

proc isEmpty*(model: TimelineBarModel): bool =
  ## Whether the pane has a recording to scrub. A model with no bounds is a
  ## session that has not reported a span yet, and `app/views/shell.nim` leaves
  ## the rectangle to CTUI-3's plain title row for it.
  not model.boundsKnown

proc totalTicks*(model: TimelineBarModel): uint64 =
  ## Ticks the recording spans, INCLUSIVE of both ends — `maxTick - minTick + 1`
  ## and not the difference, because a recording whose only tick is 0 has one
  ## tick and not none.
  if not model.boundsKnown or model.maxTick < model.minTick: 0'u64
  else: model.maxTick - model.minTick + 1

proc needleTrackColumn*(model: TimelineBarModel; trackWidth: int): int =
  columnForTick(model.currentTick, model.minTick, model.maxTick, trackWidth)

proc markTrackColumns*(model: TimelineBarModel; trackWidth: int): seq[int] =
  ## Deduplicated and ascending: see `TimelineBarScreen.markColumns`.
  result = @[]
  if trackWidth <= 0:
    return
  for mark in model.marks:
    let c = columnForTick(mark.tick, model.minTick, model.maxTick, trackWidth)
    if c >= 0 and c notin result:
      result.add c
  result.sort()

proc spanTrackColumns*(model: TimelineBarModel; trackWidth: int): seq[int] =
  result = @[]
  if trackWidth <= 0:
    return
  for span in model.spans:
    for c in trackColumnsForSpan(span, model.minTick, model.maxTick,
                                 trackWidth):
      if c notin result:
        result.add c
  result.sort()

# ---------------------------------------------------------------------------
# Painting
# ---------------------------------------------------------------------------

proc titleRowSpans*(model: TimelineBarModel; width: int): StyledRow =
  ## `TIMELINE  tick 300 / 1314  4 span(s) ────`.
  ##
  ## The tick and the total are in the title because a scrubber is a coarse
  ## instrument — one cell of a 78-cell track is seventeen ticks of
  ## `noir_space_ship` — and the exact position is what a reader comparing the
  ## pane against a `ct/complete-move` needs.
  result = @[]
  if width <= 0:
    return
  var parts: seq[StyledSpan] = @[]
  parts.add StyledSpan(text: TimelineTitle, style: TitleStyle)
  if model.boundsKnown:
    parts.add StyledSpan(text: " tick " & $model.currentTick & " / " &
                               $model.maxTick, style: TitleDetailStyle)
  else:
    parts.add StyledSpan(text: " " & UnknownBoundsText,
                         style: UnknownBoundsStyle)
  if model.spans.len > 0:
    parts.add StyledSpan(text: " " & $model.spans.len & " span(s)",
                         style: TitleDetailStyle)
  if model.marks.len > 0:
    parts.add StyledSpan(text: " " & $model.marks.len & " mark(s)",
                         style: TitleDetailStyle)
  elif model.marksNote.len > 0:
    parts.add StyledSpan(text: " " & model.marksNote,
                         style: UnknownBoundsStyle)
  var used = 0
  for part in parts:
    if used >= width:
      break
    let fitted = truncateToCells(part.text, width - used)
    if fitted.len == 0:
      continue
    result.add StyledSpan(text: fitted, style: part.style)
    used += cellWidthOf(fitted)
  if used < width:
    result.add StyledSpan(text: " ", style: DefaultCellStyle)
    inc used
  if used < width:
    result.add StyledSpan(text: repeatGlyph(PaneRule, width - used),
                          style: RuleStyle)

proc titleRowText*(model: TimelineBarModel; width: int): string =
  rowText(titleRowSpans(model, width))

proc paintTimelineBar*(g: var StyledGrid; area: CellArea;
                       model: TimelineBarModel): TimelineBarScreen =
  ## Paint the title and the scrubber into the TOP `TimelineBarRows` rows of
  ## `area`, and report every coordinate the suites read.
  ##
  ## THE PAINT ORDER IS THE PRECEDENCE ORDER and it is the pane's one semantic
  ## decision: track, then spans, then marks, then the needle. A `▲` over a `█`
  ## means "the debugger is inside this call"; a `█` over a `▲` would hide the
  ## execution pointer, which is the one thing on this bar that must never be
  ## invisible.
  result = TimelineBarScreen(
    rows: @[], area: area, barRow: -1, trackCol: -1, trackWidth: 0,
    needleColumn: -1, markColumns: @[], spanColumns: @[],
    paintedMarks: 0, paintedSpans: 0, boundsColumns: @[])
  if area.width <= 0 or area.height <= 0:
    return

  var spanAt = area.col
  for span in titleRowSpans(model, area.width):
    g.paint(area.row, spanAt, span.text, span.style)
    spanAt += cellWidthOf(span.text)

  if area.height < TimelineBarRows:
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  let barRow = area.row + 1
  result.barRow = barRow

  if not model.boundsKnown:
    let note =
      if model.boundsNote.len > 0: UnknownBoundsText & ": " & model.boundsNote
      else: UnknownBoundsText
    g.paint(barRow, area.col, truncateToCells(note, area.width),
            UnknownBoundsStyle)
    for r in area.row ..< area.row + min(area.height, TimelineBarRows):
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  let track = trackWidthFor(area.width)
  result.trackWidth = track
  if track <= 0:
    for r in area.row ..< area.row + min(area.height, TimelineBarRows):
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  result.trackCol = area.col + 1
  result.boundsColumns = @[area.col, area.col + track + 1]
  g.paint(barRow, area.col, BoundsOpenGlyph, BoundsStyle)
  g.paint(barRow, area.col + track + 1, BoundsCloseGlyph, BoundsStyle)

  # ONE `paint` for the whole track rather than one per cell. `StyledGrid.paint`
  # walks the runes of whatever it is given, so a repeated glyph costs one call
  # and one string instead of `trackWidth` of each. (The measured cost of this
  # pane's repaint was NOT here — it was the quadratic rule-fill in
  # `titleRowSpans`; see `styled_row.repeatGlyph` for the numbers.)
  g.paint(barRow, result.trackCol, repeatGlyph(TrackGlyph, track), TrackStyle)

  result.spanColumns = model.spanTrackColumns(track)
  for c in result.spanColumns:
    g.paint(barRow, result.trackCol + c, SpanGlyph, SpanStyle)

  result.markColumns = model.markTrackColumns(track)
  for c in result.markColumns:
    g.paint(barRow, result.trackCol + c, MarkGlyph, MarkStyle)

  result.needleColumn = model.needleTrackColumn(track)
  if result.needleColumn >= 0:
    g.paint(barRow, result.trackCol + result.needleColumn, NeedleGlyph,
            NeedleStyle)

  # Counted off the GRID, after everything is painted, so the numbers describe
  # the screen rather than the model. A needle standing on a mark leaves one
  # fewer diamond, and a test that read `markColumns.len` would not notice.
  for c in 0 ..< track:
    case g.runeAt(barRow, result.trackCol + c)
    of MarkGlyph: inc result.paintedMarks
    of SpanGlyph: inc result.paintedSpans
    else: discard

  for r in area.row ..< area.row + min(area.height, TimelineBarRows):
    result.rows.add g.rowSpansIn(r, area.col, area.width)

proc timelineBarScreen*(model: TimelineBarModel;
                        width, height: int): TimelineBarScreen =
  ## The scrubber on a screen of its own — the shape a Tier-1 test and the
  ## `app_timeline` snapshot app both use.
  var g = newStyledGrid(width, height)
  let area = CellArea(col: 0, row: 0, width: width, height: height)
  result = paintTimelineBar(g, area, model)

proc timelineBarRows*(model: TimelineBarModel;
                      width, height: int): seq[StyledRow] =
  timelineBarScreen(model, width, height).rows

proc timelineBarText*(model: TimelineBarModel;
                      width, height: int): seq[string] =
  ## The scrubber as plain text, one string per row. What a Tier-2 `regionText`
  ## read is compared against.
  result = @[]
  for row in timelineBarRows(model, width, height):
    result.add rowText(row)

proc trackColumnAt*(screen: TimelineBarScreen; screenRow, screenCol: int): int =
  ## Which TRACK cell a screen coordinate is in, or -1 for anywhere else.
  ##
  ## This is §4.4's mouse model expressed as arithmetic a Tier-1 test can check,
  ## so `tests/real_terminal/test_real_timeline.nim` asserts that a REAL
  ## `sendMouseClick` lands on the tick this predicted rather than re-deriving
  ## the prediction on the other side of the pty.
  if screen.barRow < 0 or screenRow != screen.barRow or screen.trackWidth <= 0:
    return -1
  let c = screenCol - screen.trackCol
  if c < 0 or c >= screen.trackWidth: -1 else: c

proc renderTimelineBarTree*(model: TimelineBarModel; r: TerminalRenderer;
                            width, height: int): TerminalNode =
  ## The scrubber as a component tree: one `div` per row, styled spans inside.
  styledRowsTree(r, timelineBarRows(model, width, height))
