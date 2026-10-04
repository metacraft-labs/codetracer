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
from codetracer_embed import CallLine, currentCallOf,
  CallRow, CallRowToggle, CallSegmentKind,
  CallSegment, callRowSegments, crtLeaf, crtExpanded, crtCollapsed,
  CallRowIndentCells,
  csIndent, csToggle, csCallee, csIndex, csPunct, csArgName, csArgValue,
  csReturnArrow, csReturnValue

import ../layout/profile
import ./styled_row

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

const
  CallTraceTitle* = "CALL TRACE"
  StackFallbackTitle* = "Call stack: this recording has no call trace"
    ## The fallback's note, painted over the call stack's own heading row.
  CallTraceLoadingText* = "  …"
    ## A row of the trace whose section has not arrived: drawn, not left
    ## blank, because a blank row reads as the end of the trace.
  CallTraceTitleStyle = CellStyle(role: srChromeTitle)
  CallTraceCountStyle = CellStyle(role: srChromeMuted)
  CallTraceRuleStyle = CellStyle(role: srBorderPane)
  CallTraceLoadingStyle = CellStyle(role: srChromeMuted)
  CallTraceRuleGlyph = "─"

proc initCallTraceModel*(rows: seq[CallTraceRow] = @[];
                         tick: uint64 = 0;
                         stack: seq[string] = @[];
                         firstIndex = 0'i64;
                         total = -1;
                         scrollTop = 0;
                         follow = true): CallTraceModel =
  ## The model for the loaded section `rows` (the trace's calls from
  ## `firstIndex`) at `tick`, with the call STACK at that stop (innermost
  ## first) when the host has it. `total` is the whole trace's call count;
  ## -1 means the section is the whole trace.
  ##
  ## The current call is the call the debugger is IN: the last row entered at
  ## or before `tick` whose name is the innermost frame's and whose depth is
  ## the stack's (`stack.len - 1`, the trace's root being depth 0). A call
  ## that has already returned is entered before `tick` too, so "the last row
  ## entered" alone would mark `mul` while the debugger is back in `main`.
  ## With no stack, that is the fallback.
  result = CallTraceModel(rows: rows, current: -1, firstIndex: firstIndex,
                          total: max(total, firstIndex.int + rows.len),
                          scrollTop: max(0, scrollTop), follow: follow)
  # The ViewModel's rule (`calltrace_vm.currentCallOf`, PLAT-49 part B) —
  # GPUI selects the same call from it.
  var lines: seq[CallLine] = @[]
  for i, r in rows:
    lines.add CallLine(index: i.int64, name: r.name, depth: r.depth,
                       rrTicks: r.rrTicks)
  let at = currentCallOf(lines, tick, stack)
  if at.isSome:
    result.current = at.get.int

proc isEmpty*(m: CallTraceModel): bool = m.total == 0

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

proc rowAt*(m: CallTraceModel; index: int): (bool, CallTraceRow) =
  ## The trace's call `index`, when its section is loaded.
  let local = index - m.firstIndex.int
  if local >= 0 and local < m.rows.len: (true, m.rows[local])
  else: (false, CallTraceRow())

proc titleText*(m: CallTraceModel; width: int): string =
  ## `CALL TRACE 29 call(s) ────`: the whole trace's count, not the section's.
  var line = CallTraceTitle & " " & $m.total & " call(s)"
  if cellWidthOf(line) + 1 <= width:
    line.add " "
    line.add repeatGlyph(CallTraceRuleGlyph, width - cellWidthOf(line))
  truncateToCells(line, width)

proc paintCallTrace*(g: var StyledGrid; area: CellArea;
                     m: CallTraceModel): int =
  ## Paint the pane into `area`; returns the number of call rows drawn (a
  ## row whose section has not arrived is drawn as `CallTraceLoadingText` and
  ## not counted).
  if area.width <= 0 or area.height <= 0:
    return 0
  let title = titleText(m, area.width)
  g.paint(area.row, area.col, title, CallTraceRuleStyle)
  let label = CallTraceTitle
  let count = " " & $m.total & " call(s)"
  g.paint(area.row, area.col, truncateToCells(label, area.width),
          CallTraceTitleStyle)
  if cellWidthOf(label) < area.width:
    g.paint(area.row, area.col + cellWidthOf(label),
            truncateToCells(count, area.width - cellWidthOf(label)),
            CallTraceCountStyle)
  let bodyRows = area.height - 1
  let top = m.visibleTop(bodyRows)
  let current = if m.current >= 0: m.firstIndex.int + m.current else: -1
  for i in 0 ..< bodyRows:
    let index = top + i
    if index >= m.total:
      break
    let (loaded, r) = m.rowAt(index)
    if not loaded:
      g.paint(area.row + 1 + i, area.col,
              truncateToCells(CallTraceLoadingText, area.width),
              CallTraceLoadingStyle)
      continue
    # PLAT-49 part B: EACH PART IN ITS OWN STYLE (`segmentStyle`), and the
    # call the debugger is in marked as the desktop marks it
    # (`onCompleteMove` -> `selectEntry`: `.event-selected`, its own ground,
    # and `.call-current`, bold) — the whole row on the active-row ground.
    let isCurrent = index == current
    let y = area.row + 1 + i
    var x = area.col
    let stop = area.col + area.width
    if isCurrent:
      g.paint(y, area.col, spaces(area.width), CurrentRowFill)
    for seg in callRowSegments(r.callOf):
      if x >= stop:
        break
      let fitted = truncateToCells(seg.text, stop - x)
      if fitted.len == 0:
        continue
      g.paint(y, x, fitted, segmentStyle(seg.kind, isCurrent))
      x += cellWidthOf(fitted)
    inc result

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

  CallTraceHit* = object
    kind*: CallTraceHitKind
    index*: int64
      ## The trace index of the call under the pointer.
    arg*: int
      ## PLAT-50 (K23): the argument under the pointer (its name, `=` or
      ## value), an index into the row's `args`; -1 for none.

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
  let bodyRows = area.height - 1
  let index = m.visibleTop(bodyRows) + (row - area.row - 1)
  if index >= m.total:
    return CallTraceHit(kind: cthNone, arg: -1)
  let (loaded, r) = m.rowAt(index)
  if not loaded:
    return CallTraceHit(kind: cthNone, arg: -1)
  let call = r.callOf
  # The toggle's cell: after the depth's indent (`callRowSegments`).
  let toggleCol = area.col + call.depth * CallRowIndentCells
  if col == toggleCol and call.toggle != crtLeaf:
    return CallTraceHit(kind: cthToggle, index: index.int64, arg: -1)
  # PLAT-50: which argument the pointer is on — walked over the same
  # segments `paintCallTrace` draws, each argument being its name, its `=`
  # and its value (the desktop's `.call-arg`).
  var x = area.col
  var arg = -1
  for seg in callRowSegments(call):
    let w = cellWidthOf(seg.text)
    if col >= x and col < x + w:
      arg = seg.arg - 1
      break
    x += w
  CallTraceHit(kind: cthRow, index: index.int64, arg: arg)
