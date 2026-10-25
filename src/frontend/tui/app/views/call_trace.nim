## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/views/call_trace.nim — PLAT-47 deliverable 7. **The CALL TRACE pane:
## the recording's calls, as the desktop's calltrace pane lists them.**
##
## The shared default places `paneCalltrace` where the desktop shows its
## CALLTRACE panel — the tree of every call the recording made, `<toplevel>
## #0`, `<__main__> #1`, `main #2`, `evaluate #3` … — and the terminal used to
## draw a call STACK there: the frames live at this stop, which on the `calc`
## recording is one row where the desktop shows twenty-nine. The user reported
## it on 2026-09-27.
##
## So the pane now draws the call TRACE whenever the recording provides one,
## from the same data the desktop's pane renders: the `CallLine` rows the
## session's `CalltraceVM` exposes (`visibleLines`, over the store's
## `calltrace.lines`, which `native_host.loadRecordingPanes` loads with the
## desktop's own `ct/load-calltrace-section`). Each row is the desktop's
## `.call-text` — `name #index` — indented by the call's depth.
##
## When the recording provides no call trace, the pane falls back to the call
## STACK and SAYS SO in its title (`StackFallbackTitle`), because a pane
## that silently changed what it lists is one a user cannot read.

import std/[options, strutils]

# PLAT-49 part B: the row's parts are the Call Trace ViewModel's `CallRow`.
from codetracer_embed import CallLine, currentCallInSectionOf,
  CallRow, CallRowToggle, CallSegmentKind,
  CallSegment, callRowSegments, crtLeaf, crtExpanded, crtCollapsed,
  CallToggleGlyphs, csToggle,
  CallRowIndentCells,
  csIndent, csToggle, csCallee, csIndex, csPunct, csArgName, csArgValue,
  csReturnArrow, csReturnValue
# PLAT-51: the scrollbar scrubber's shared model.
from codetracer_embed import ScrubberModel, scrubberModel
# PLAT-70 Part B: the row's one composite text, cut with `…`, its full text
# on hover and under the row (Horizontal-Overflow.md §5).
from codetracer_embed import callRowText, fitCell, CutCell, DetailToggle, Ellipsis,
  CallTraceTablePane,
  detailView, isOpen
# PLAT-70 Part I: fit or scroll — the row column's floor is the deepest
# shown row's indent and callee name (Horizontal-Overflow.md §5.5).
from codetracer_embed import TableFit, CompositeRow, callFitRow, compositeFit,
  compositeWidth, settle, overflows, barModel, HorizontalView
from ../formatters/type_formatters import terminalMeasure, measureOf

import ../layout/profile
import ./styled_row
import ./scrubber_track
import ./table_hscroll

export styled_row, profile
export CallRow, CallRowToggle, CallSegmentKind, CallSegment, callRowSegments

type
  CallTraceRow* = object
    ## One call, as the desktop's calltrace row names it.
    index*: int64
    name*: string
      ## `displayName` when the store has one, else `name` — the desktop's
      ## `callDisplayName`.
    depth*: int
    rrTicks*: uint64
    call*: CallRow
      ## PLAT-49 part B: THE WHOLE ROW, semantically — callee, arguments with
      ## their values, return value, toggle state — as the Call Trace
      ## ViewModel gives it (`calltrace_vm.callRowOf`). A row built with only
      ## the four fields above gets one from them (`callOf`).

  CallTraceModel* = object
    ## THE LOADED WINDOW of the trace, not the trace. The trace is read a
    ## section at a time (`ct/load-calltrace-section`, the request the
    ## desktop's `CalltraceVM` pages with) and the host asks for the next
    ## section as the reader scrolls (`tui_session.pageCallTrace`), so a
    ## recording with ten thousand calls costs one window of rows here.
    rows*: seq[CallTraceRow]
      ## The loaded section: `rows[i]` is the trace's call `firstIndex + i`.
    firstIndex*: int64
      ## The trace index of `rows[0]` (the section's `startCallLineIndex`).
    total*: int
      ## How many calls the whole trace lists (the section's
      ## `totalCallsCount`); at least `firstIndex + rows.len`.
    current*: int
      ## Index into `rows` of the call the debugger is in — the deepest call
      ## entered at or before the current tick — or -1 (not in the loaded
      ## section, or no trace).
    scrollTop*: int
      ## The trace index of the first row the pane shows.
    follow*: bool
      ## Keep the current call on screen. True until the reader scrolls the
      ## pane; `.` (centre on the pointer) turns it back on.
    currentIndex*: int
      ## PLAT-51: the TRACE index of the call the debugger is in, from the
      ## engine (`currentCallLineIndex`) — known even when that call is not in
      ## the loaded section — or -1. The scrubber track's mark.
    detail*: DetailToggle
      ## PLAT-70 Part B: the call whose full text is open under its row; its
      ## key is the call's trace index.
    copyChord*: string
      ## The resolved `list.copy` chord the detail's hint names (KL-8).
    hview*: HorizontalView
      ## PLAT-70 Part I: the rows' horizontal view (Horizontal-Overflow.md
      ## §5.5.5) — what the wheel and the bar move; settled over each
      ## frame's fit.

  CallTraceLine* = object
    ## PLAT-70 Part B: one body line — a call's row, or a line of the full
    ## text open under it.
    index*: int
      ## The trace index of the call.
    detail*: int
      ## -1 for the call's own row, else the detail line's number.
    text*: string
      ## A detail line's text.

  CallTraceScreen* = object
    ## What `paintCallTraceScreen` drew.
    drawn*: int
      ## Call rows drawn (a row whose section has not arrived is not counted).
    cuts*: seq[CutCell]
      ## Every row drawn cut, with its `…` (HO-8).
    detailRows*: seq[int]
      ## The SCREEN rows the open detail's lines are on.
    fit*: TableFit
      ## PLAT-70 Part I: the row column's fit this frame.
    hview*: HorizontalView
      ## The horizontal view the rows were drawn from.
    barRow*: int
      ## The SCREEN row of the horizontal bar, -1 when none is drawn.

const
  CallTracePaneName* = CallTraceTablePane
    ## PLAT-70 Part B: this pane's name in a `DetailToggle` / a cut cell.
  CallTraceTitle* = "CALL TRACE"
  StackFallbackTitle* = "Call stack: this recording has no call trace"
    ## The fallback's note, painted over the call stack's own heading row.
  CallTraceLoadingText* = "  " & canonical(grTruncation)
    ## A row of the trace whose section has not arrived: drawn, not left
    ## blank, because a blank row reads as the end of the trace.
  CallTraceTitleStyle = CellStyle(role: srChromeTitle)
  CallTraceCountStyle = CellStyle(role: srChromeMuted)
  CallTraceRuleStyle = CellStyle(role: srBorderPane)
  CallTraceLoadingStyle = CellStyle(role: srChromeMuted)
  CallTraceDetailStyle = CellStyle(role: srChromeText)
  CallTraceRuleGlyph = canonical(grDividerH)

proc initCallTraceModel*(rows: seq[CallTraceRow] = @[];
                         tick: uint64 = 0;
                         stack: seq[string] = @[];
                         firstIndex = 0'i64;
                         total = -1;
                         scrollTop = 0;
                         follow = true;
                         currentIndex = -1): CallTraceModel =
  ## The model for the loaded section `rows` (the trace's calls from
  ## `firstIndex`, in order, each with its depth) at `tick`, with the call
  ## STACK at that stop (innermost first) when the host has it. `total` is
  ## the whole trace's call count; -1 means the section is the whole trace.
  ## `currentIndex` is the engine's `currentCallLineIndex` (a trace index),
  ## or -1.
  ##
  ## The current call is the call the debugger is IN, by the ViewModel's
  ## rule (`calltrace_vm.currentCallOf`): the last row entered at or before
  ## `tick` whose name is the innermost frame's and whose depth is the
  ## stack's (`stack.len - 1`, the trace's root being depth 0), and which
  ## has not returned. A row has returned when a later row entered by `tick`
  ## is at its depth or shallower. So a call hidden by a collapsed parent
  ## leaves NO row current; it never moves the mark to an earlier call of
  ## the same name that returned (codetracer#845). With no stack, the
  ## current row is the last row entered.
  ##
  ## A section that ends before the trace does, with no row after the answer
  ## entered after `tick`, cannot show that the answer has not returned
  ## (the row that shows it may be past the section's end). The answer is
  ## then kept only when the engine's `currentIndex` names the same call
  ## (`calltrace_vm.currentCallInSectionOf`).
  result = CallTraceModel(rows: rows, current: -1, firstIndex: firstIndex,
                          total: max(total, firstIndex.int + rows.len),
                          scrollTop: max(0, scrollTop), follow: follow,
                          currentIndex: currentIndex)
  # The ViewModel's rule (`calltrace_vm.currentCallOf`, PLAT-49 part B) —
  # GPUI selects the same call from it.
  var lines: seq[CallLine] = @[]
  for i, r in rows:
    lines.add CallLine(index: i.int64, name: r.name, depth: r.depth,
                       rrTicks: r.rrTicks)
  let engineAt = if currentIndex >= 0: currentIndex.int64 - firstIndex
                 else: -1'i64
  let at = currentCallInSectionOf(lines, tick, stack,
    reachesTraceEnd = firstIndex.int + rows.len >= result.total,
    engineIndex = engineAt)
  if at.isSome:
    result.current = at.get.int

proc isEmpty*(m: CallTraceModel): bool = m.total == 0

const
  MinTrackedWidth* = 8
    ## PLAT-51: the narrowest pane that gives a column to the scrubber.

proc tracked*(area: CellArea): bool =
  ## Whether a pane painted into `area` carries the scrubber column.
  area.width >= MinTrackedWidth and area.height > 1

proc currentTraceIndex*(m: CallTraceModel): int =
  ## The trace index of the call the debugger is in, or -1.
  ## The loaded section's answer wins when it has one: it is the ViewModel's
  ## exact rule (`currentCallOf`, by tick and stack), which never names a
  ## call that has returned, and which the section answers only when it can
  ## show that (`initCallTraceModel`). The engine's `currentCallLineIndex`
  ## places the mark otherwise: when the call is outside the section, when
  ## the section cannot show its answer has not returned, and when a
  ## collapsed parent hides the call (the engine then names that parent, the
  ## last listed call keyed at or before the current one).
  if m.current >= 0: m.firstIndex.int + m.current
  elif m.currentIndex >= 0: m.currentIndex
  else: -1

proc callOf*(r: CallTraceRow): CallRow =
  ## The row's `CallRow`: the ViewModel's when the host gave one, else one
  ## made of the row's name, depth and index (a leaf with no arguments).
  if r.call.callee.len > 0:
    return r.call
  CallRow(index: r.index, depth: max(0, r.depth), callee: r.name,
          toggle: crtLeaf, rrTicks: r.rrTicks)

proc rowText*(r: CallTraceRow): string =
  ## The row as the terminal draws it: indented by depth, the toggle, the
  ## desktop's `.call-text` (`evaluate #3`), its `.call-args`
  ## (`(expression=2 + 3)`) and its `.return` (` => 5`).
  for seg in callRowSegments(r.callOf):
    result.add seg.text

func segmentStyle*(kind: CallSegmentKind; current: bool): CellStyle =
  ## How each part of a row is styled — the desktop's classes, as roles:
  ## the name in the body text, the argument list in CALLTRACE_ARGS_COLOR,
  ## the return in CALLTRACE_RETURN_COLOR, the toggle muted. THE CALL THE
  ## DEBUGGER IS IN is the desktop's selected row: `.event-selected` (its own
  ## ground) with `.call-current` (bold name) and the toggle's `active` icon —
  ## here its name is bold and its toggle takes the body colour, legible on
  ## the row's ground (`CurrentRowFill`, painted under the parts: a part
  ## names no surface, so it keeps the one under it).
  case kind
  of csIndent, csCallee, csIndex: CellStyle(role: srChromeText, bold: current)
  of csToggle:
    CellStyle(role: (if current: srChromeText else: srChromeMuted))
  of csPunct, csArgName, csArgValue: CellStyle(role: srCallArgs)
  of csReturnArrow, csReturnValue: CellStyle(role: srCallReturn)

const CurrentRowFill* = CellStyle(surface: srSurfaceActiveRow)
  ## The current call's row ground (`srSurfaceActiveRow`, the design
  ## system's active-row token), the pane's whole width as the desktop's row.

proc clampTop*(m: CallTraceModel; top, bodyRows: int): int =
  ## `top` kept inside the trace: never above its first call, and never so
  ## far down that the pane's last row is past its last call.
  max(0, min(top, m.total - max(1, bodyRows)))

proc visibleTop*(m: CallTraceModel; bodyRows: int): int =
  ## The trace index of the first row the pane shows at `bodyRows` rows:
  ## `scrollTop`, moved just enough to keep the current call on screen while
  ## the pane FOLLOWS it (the reader has not scrolled away).
  var top = m.scrollTop
  if m.follow and m.current >= 0 and bodyRows > 0:
    let at = m.firstIndex.int + m.current
    if at < top: top = at
    elif at >= top + bodyRows: top = at - bodyRows + 1
  m.clampTop(top, bodyRows)

proc scrubberOf*(m: CallTraceModel; bodyRows: int): ScrubberModel =
  ## PLAT-51: the scrollbar scrubber over the WHOLE trace at its current
  ## expansion (Scrollbar-Scrubbers.md §2: `totalCallsCount`, not the loaded
  ## section) — the view's top and height, and the current call's row.
  scrubberModel(m.total, m.visibleTop(bodyRows), bodyRows, m.currentTraceIndex)

proc rowAt*(m: CallTraceModel; index: int): (bool, CallTraceRow) =
  ## The trace's call `index`, when its section is loaded.
  let local = index - m.firstIndex.int
  if local >= 0 and local < m.rows.len: (true, m.rows[local])
  else: (false, CallTraceRow())

proc titleText*(m: CallTraceModel; width: int;
                glyphs = DefaultGlyphs): string =
  ## `CALL TRACE 29 call(s) ────`: the whole trace's count, not the section's.
  var line = CallTraceTitle & " " & $m.total & " call(s)"
  if cellWidthOf(line) + 1 <= width:
    line.add " "
    line.add repeatGlyph(glyphs.glyph(grDividerH), width - cellWidthOf(line))
  truncateToCells(line, width)

proc rowStartCol(r: CallTraceRow): int =
  ## Cells before the row's text: the depth's indent, the toggle and its gap.
  let call = r.callOf
  call.depth * CallRowIndentCells + 2

type
  CallTraceGeometry* = object
    ## PLAT-70 Part I: where the pane's parts go this frame — read by the
    ## painter, the hit-test and the runtime's wheel and bar, so a gesture and
    ## the drawing cannot disagree.
    rowWidth*: int
      ## The cells the rows are shown in (the scrubber's column excluded).
    bodyRows*: int
      ## The body's rows, less the bar's row while it is shown.
    fit*: TableFit
    view*: HorizontalView
    barRow*: int
      ## The SCREEN row of the horizontal bar, -1 when none.

proc callTraceGeometry*(m: CallTraceModel; area: CellArea): CallTraceGeometry =
  ## The row column's fit over the rows the body shows (§5.5.3: each row's
  ## floor is its indent, its toggle and its callee's name, its preferred
  ## width its whole text), the view settled over it, and — in SCROLL, when
  ## the body has a row to spare — §4.7's bar on the body's last row.
  result.barRow = -1
  result.rowWidth = if area.tracked: area.width - ScrubberTrackCells
                    else: area.width
  result.bodyRows = max(0, area.height - 1)
  var rows: seq[CompositeRow]
  let top = m.visibleTop(result.bodyRows)
  for index in top ..< min(m.total, top + result.bodyRows):
    let (loaded, r) = m.rowAt(index)
    if not loaded:
      continue
    let call = r.callOf
    rows.add callFitRow(r.rowStartCol, cellWidthOf(call.callee),
                        cellWidthOf(callRowText(call)))
  result.fit = compositeFit(rows, max(0, result.rowWidth), "call")
  result.view = m.hview
  result.view.settle(result.fit)
  if result.fit.overflows and result.bodyRows > 1:
    dec result.bodyRows
    result.barRow = area.row + 1 + result.bodyRows

proc callTraceBodyRows*(m: CallTraceModel; area: CellArea): int =
  ## The rows the body shows (the bar's row excluded).
  m.callTraceGeometry(area).bodyRows

proc bodyLines*(m: CallTraceModel; area: CellArea): seq[CallTraceLine] =
  ## PLAT-70 Part B: the pane's body, line by line — each call from the
  ## visible top, and under the one whose detail is open its full text
  ## (Horizontal-Overflow.md §5.3) — as many as the body has rows. The ONE
  ## layout `paintCallTraceScreen` draws and `callTraceHitAt` reads.
  let geo = m.callTraceGeometry(area)
  let bodyRows = geo.bodyRows
  if area.width <= 0 or bodyRows <= 0:
    return
  let rowWidth = geo.rowWidth
  var index = m.visibleTop(bodyRows)
  while result.len < bodyRows and index < m.total:
    result.add CallTraceLine(index: index, detail: -1)
    let (loaded, r) = m.rowAt(index)
    if loaded and m.detail.isOpen(CallTracePaneName, $index):
      let at = clamp(r.rowStartCol - geo.view.leftCol, 0, max(0, rowWidth - 1))
      let view = detailView(callRowText(r.callOf), max(1, rowWidth - at),
                            bodyRows, m.copyChord, terminalMeasure)
      for k, text in view.lines:
        if result.len >= bodyRows:
          break
        result.add CallTraceLine(index: index, detail: k, text: text)
    inc index

proc paintCallTraceScreen*(g: var StyledGrid; area: CellArea;
                           m: CallTraceModel): CallTraceScreen =
  ## Paint the pane into `area`, and report what was drawn.
  ##
  ## PLAT-70 Part I (Horizontal-Overflow.md §5.5.5): the rows are laid out at
  ## the row column's width — the pane's in FIT and SHRINK, the deepest
  ## shown row's floor in SCROLL — into a scratch grid, and the window
  ## `[leftCol, leftCol + rowWidth)` of each is copied to the pane.
  result.barRow = -1
  if area.width <= 0 or area.height <= 0:
    return
  let title = titleText(m, area.width, g.glyphs)
  g.paint(area.row, area.col, title, CallTraceRuleStyle)
  let label = CallTraceTitle
  let count = " " & $m.total & " call(s)"
  g.paint(area.row, area.col, truncateToCells(label, area.width),
          CallTraceTitleStyle)
  if cellWidthOf(label) < area.width:
    g.paint(area.row, area.col + cellWidthOf(label),
            truncateToCells(count, area.width - cellWidthOf(label)),
            CallTraceCountStyle)
  let geo = m.callTraceGeometry(area)
  result.fit = geo.fit
  result.hview = geo.view
  let bodyRows = geo.bodyRows
  let current = if m.current >= 0: m.firstIndex.int + m.current else: -1
  # PLAT-51: THE RIGHTMOST COLUMN IS THE SCROLLBAR SCRUBBER (Scrollbar-
  # Scrubbers.md §4), the rows laid out in the cells left of it.
  let hasTrack = area.tracked
  let rowWidth = geo.rowWidth
  let left = geo.view.leftCol
  let tableW = max(rowWidth, geo.fit.compositeWidth)
  if hasTrack:
    paintVerticalScrubber(g, area.col + rowWidth, area.row + 1, bodyRows,
                          m.scrubberOf(bodyRows))
  if geo.barRow >= 0:
    # §4.7: the bar on the body's last row; the corner is neither track's.
    result.barRow = geo.barRow
    paintHorizontalBar(g, geo.barRow, area.col, rowWidth, geo.view.barModel)
  var table = newStyledGridLike(g, tableW, 1)
  for i, line in m.bodyLines(area):
    let index = line.index
    let y = area.row + 1 + i
    let (loaded, r) = m.rowAt(index)
    if line.detail >= 0:
      let at = area.col + clamp(r.rowStartCol - left, 0, max(0, rowWidth - 1))
      g.paint(y, at, line.text, CallTraceDetailStyle)
      result.detailRows.add y
      continue
    if not loaded:
      g.paint(y, area.col, truncateToCells("  " & g.glyphText(grTruncation),
                                           rowWidth),
              CallTraceLoadingStyle)
      continue
    # PLAT-49 part B: EACH PART IN ITS OWN STYLE (`segmentStyle`), and the
    # call the debugger is in marked as the desktop marks it
    # (`onCompleteMove` -> `selectEntry`: `.event-selected`, its own ground,
    # and `.call-current`, bold) — the whole row on the active-row ground.
    let isCurrent = index == current
    table = newStyledGridLike(g, tableW, 1)
    var x = 0
    let stop = tableW
    if isCurrent:
      table.paint(0, 0, spaces(tableW), CurrentRowFill)
    # PLAT-70 Part B (Horizontal-Overflow.md §5.1): THE ROW IS ONE CELL — its
    # text (name, arguments, return) after the indent and the toggle — fitted
    # by `fitCell` to the row column's width; a cut row keeps its parts'
    # styles up to the `…`.
    let textAt = min(tableW, r.rowStartCol)
    let full = callRowText(r.callOf)
    let fitted = fitCell(full, stop - textAt, measureOf(g))
    let keep = if fitted.truncated:
                 textAt + cellWidthOf(fitted.text, g.ambiguous) -
                   g.glyphs.markerCells
               else: stop
    var lastStyle = segmentStyle(csCallee, isCurrent)
    for seg in callRowSegments(r.callOf):
      if x >= keep:
        break
      # PLAT-71: the shared row's toggle is the desktop's icon; the terminal
      # draws it from the glyph table's column (`·` / `▾` / `▸`, one cell on
      # every tier).
      let segText =
        if seg.kind == csToggle:
          (if seg.text == CallToggleGlyphs[crtExpanded]:
             g.glyphText(grCallExpanded)
           elif seg.text == CallToggleGlyphs[crtCollapsed]:
             g.glyphText(grCallCollapsed)
           else: g.glyphText(grCallLeaf))
        else: seg.text
      let piece = truncateToCells(segText, keep - x)
      if piece.len == 0:
        continue
      lastStyle = segmentStyle(seg.kind, isCurrent)
      table.paint(0, x, piece, lastStyle)
      x += cellWidthOf(piece)
    var cuts: seq[CutCell]
    if fitted.truncated and stop > textAt:
      table.paint(0, keep, g.glyphText(grTruncation), lastStyle)
      cuts.add CutCell(row: y, col: textAt, width: stop - textAt,
                       ellipsisCol: keep, key: $index,
                       column: "call", full: full)
    g.copySlice(y, area.col, table, 0, left, rowWidth)
    result.cuts.add shiftCuts(cuts, area.col - left, area.col,
                              area.col + rowWidth)
    inc result.drawn

proc paintCallTrace*(g: var StyledGrid; area: CellArea;
                     m: CallTraceModel): int =
  ## Paint the pane into `area`; returns the number of call rows drawn (a
  ## row whose section has not arrived is drawn as `CallTraceLoadingText` and
  ## not counted).
  paintCallTraceScreen(g, area, m).drawn

proc paintFallbackCaption*(g: var StyledGrid; area: CellArea) =
  ## The call-stack fallback's note, on the pane's first content row (in
  ## place of the stack's own heading): the pane is showing the STACK because
  ## the recording provides no call trace. A sentence, not a title bar
  ## (PLAT-49): no rule, the muted caption tier.
  if area.width <= 0 or area.height <= 0:
    return
  g.paint(area.row, area.col, spaces(area.width), CallTraceCountStyle)
  g.paint(area.row, area.col, truncateToCells(StackFallbackTitle, area.width),
          CallTraceCountStyle)

type
  CallTraceHitKind* = enum
    cthNone      ## not on a call row
    cthRow       ## on a call row: go to that call (the desktop's click)
    cthToggle    ## on the row's toggle: expand or collapse its children
    cthTrack     ## PLAT-51: on the scrollbar scrubber's track (a jump)
    cthThumb     ## PLAT-51: on the scrubber's thumb (a drag starts)

  CallTraceHit* = object
    kind*: CallTraceHitKind
    index*: int64
      ## The trace index of the call under the pointer.
    arg*: int
      ## PLAT-50 (K23): the argument under the pointer (its name, `=` or
      ## value), an index into the row's `args`; -1 for none.
    fraction*: float
      ## PLAT-51: on the scrubber, where along its track (the model's
      ## fraction).

proc callTraceHitAt*(m: CallTraceModel; area: CellArea;
                     row, col: int): CallTraceHit =
  ## PLAT-49 part B: what a press at `(row, col)` is on, for the pane painted
  ## into `area` by `paintCallTrace` — the same rows, the same top, the same
  ## segments, so a click and the drawing cannot disagree. A row whose section
  ## has not arrived is not a call yet.
  if area.width <= 0 or area.height <= 1 or row <= area.row or
     row >= area.row + area.height or col < area.col or
     col >= area.col + area.width:
    return CallTraceHit(kind: cthNone, arg: -1)
  let geo = m.callTraceGeometry(area)
  let bodyRows = geo.bodyRows
  if row >= area.row + 1 + bodyRows:
    # PLAT-70 Part I: the horizontal bar's row (the runtime's bar route).
    return CallTraceHit(kind: cthNone, arg: -1)
  if area.tracked and col == area.col + area.width - ScrubberTrackCells:
    let hit = m.scrubberOf(bodyRows).verticalScrubberHit(area.row + 1,
                                                          bodyRows, row)
    return CallTraceHit(kind: (if hit.kind == shThumb: cthThumb
                               else: cthTrack),
                        index: -1, arg: -1, fraction: hit.fraction)
  let lines = m.bodyLines(area)
  let at = row - area.row - 1
  if at < 0 or at >= lines.len or lines[at].detail >= 0:
    return CallTraceHit(kind: cthNone, arg: -1)
  let index = lines[at].index
  let (loaded, r) = m.rowAt(index)
  if not loaded:
    return CallTraceHit(kind: cthNone, arg: -1)
  let call = r.callOf
  # The toggle's cell: after the depth's indent (`callRowSegments`).
  # PLAT-70 Part I: the rows are drawn from the view's `leftCol`.
  let origin = area.col - geo.view.leftCol
  let toggleCol = origin + call.depth * CallRowIndentCells
  if col == toggleCol and call.toggle != crtLeaf:
    return CallTraceHit(kind: cthToggle, index: index.int64, arg: -1)
  # PLAT-50: which argument the pointer is on — walked over the same
  # segments `paintCallTrace` draws, each argument being its name, its `=`
  # and its value (the desktop's `.call-arg`).
  var x = origin
  var arg = -1
  for seg in callRowSegments(call):
    let w = cellWidthOf(seg.text)
    if col >= x and col < x + w:
      arg = seg.arg - 1
      break
    x += w
  CallTraceHit(kind: cthRow, index: index.int64, arg: arg)
