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

import std/strutils

import ../layout/profile
import ./styled_row

export styled_row, profile

type
  CallTraceRow* = object
    ## One call, as the desktop's calltrace row names it.
    index*: int64
    name*: string
      ## `displayName` when the store has one, else `name` — the desktop's
      ## `callDisplayName`.
    depth*: int
    rrTicks*: uint64

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
  StackFallbackTitle* = "CALL STACK (no call trace in this recording)"
    ## The fallback's title, painted over the call stack's own title row.
  CallTraceLoadingText* = "  …"
    ## A row of the trace whose section has not arrived: drawn, not left
    ## blank, because a blank row reads as the end of the trace.
  CallTraceTitleStyle = CellStyle(role: srChromeTitle)
  CallTraceCountStyle = CellStyle(role: srChromeMuted)
  CallTraceRuleStyle = CellStyle(role: srBorderPane)
  CallTraceRowStyle = CellStyle(role: srChromeText)
  CallTraceLoadingStyle = CellStyle(role: srChromeMuted)
  CallTraceCurrentStyle = CellStyle(role: srChromeText, bold: true)
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
  var lastEntered = -1
  for i, r in rows:
    if r.rrTicks > tick:
      continue
    lastEntered = i
    if stack.len > 0 and r.name == stack[0] and r.depth == stack.len - 1:
      result.current = i
  if result.current < 0 and stack.len == 0:
    result.current = lastEntered

proc isEmpty*(m: CallTraceModel): bool = m.total == 0

proc rowText*(r: CallTraceRow): string =
  ## The desktop's `.call-text`, indented by depth: `  evaluate #3`.
  repeat("  ", max(0, r.depth)) & r.name & " #" & $r.index

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
    let style = if index == current: CallTraceCurrentStyle
                else: CallTraceRowStyle
    let marker = if index == current: ">" else: " "
    g.paint(area.row + 1 + i, area.col,
            truncateToCells(marker & rowText(r), area.width), style)
    inc result

proc paintFallbackCaption*(g: var StyledGrid; area: CellArea) =
  ## The call-stack fallback's title row: says the pane is showing the STACK
  ## because the recording provides no call trace.
  if area.width <= 0 or area.height <= 0:
    return
  var line = StackFallbackTitle
  if cellWidthOf(line) + 1 <= area.width:
    line.add " "
    line.add repeatGlyph(CallTraceRuleGlyph, area.width - cellWidthOf(line))
  g.paint(area.row, area.col, truncateToCells(line, area.width),
          CallTraceRuleStyle)
  g.paint(area.row, area.col,
          truncateToCells(StackFallbackTitle, area.width),
          CallTraceTitleStyle)
