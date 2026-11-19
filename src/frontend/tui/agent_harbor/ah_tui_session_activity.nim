## tui/agent_harbor/ah_tui_session_activity.nim — CTF-P2b. The terminal's
## session activity timeline: the cardless timeline of one Agent Harbor
## session over `SessionTimelineVM` (nim-agents-isonim-viewmodels), as the
## web (`isonim_agent_harbor_session_activity_view`) and GPUI
## (`gpui/agent_harbor/ah_session_activity.nim`) draw it.
##
## Cardless, as every terminal view: no frame, rule or ground around an
## event. Every line is drawn on the panel's ground; indentation, a leading
## glyph and the ink and weight of its role tell lines apart. Only the
## focused line differs, by an inset bar `▎` in the action ink in its first
## cell, never a fill. An operator's message starts a turn: a blank row
## before it, a `›` in the action ink, its words in the label ink and bold.
## A quiet gap line (`5 min later`) sits where the session paused. An
## expandable line carries `▸` / `▾`; a press on the line opens or closes it
## through the viewmodel (`toggle`). A running command carries `●` in the
## running ink.
##
## Prose (the operator's and the agent's words, a question, a failure, a
## detail, a trace) wraps and is never cut; every other line is one row, cut
## by the views' one rule (`elide`), and a file path in it is cut in its
## middle (`elidePath`, `src/…/client.py`).
##
## Chrome, above and below the lines:
##
## - the head band: the session's status (as a fleet row says it) and, when
##   the host set one, the connection badge on the right;
## - while a filter is set, a row with the query and its count;
## - while the running command's line is out of view, a `Running: <command>`
##   strip on the raised ground (the one ground step a cardless view allows);
## - while the reader does not follow and items arrived, an
##   `N new · Jump to latest` chip on the bottom row; a press jumps.
##
## Following: while the viewmodel follows (`follow`), the last lines are
## drawn; otherwise the anchor line (`anchor`) is drawn first, so new lines
## never move what the reader reads. `scrollActivity` moves the view and
## tells the viewmodel where the reader is (`readAt`, `setFollow`).
##
## Keys and presses are routed (`agent_harbor_activity_words`): a host
## resolves a key in `SessionActivityScope` and hands the operation to
## `runActivityOperation`; a press's target (the hit test) hands the
## operation its element carries and its target to the host's
## `ActivityPress`, which resolves it through its router and runs it
## (`runActivityPress`). Each such element is tagged `operation` and
## `target`. With no `press`, a press runs the carried operation itself.
##
## Facts (`AhNode`): `surface`, `state`, `session-status`, `connection` on the
## panel; `lineFacts` on every line (`line`, `line-kind`, `level`, `text`,
## `role`, `expanded`, `focused`, a group's `count`, `failed`, `running`,
## `path`, `copy`); `running-strip`, `unseen` and `filter` on the chrome.

import std/strutils
import nim_agents_isonim_viewmodels/agent_harbor/session_timeline_vm
import ../../viewmodel/views/agent_harbor_activity_words

import ./ah_tui_canvas

export session_timeline_vm, agent_harbor_activity_words, ah_tui_canvas

const
  IndentCells* = 2
    ## Each drill-down level is indented two cells.
  GlyphCells* = 2
    ## A line's leading glyph (`▸`, `▾`, `›`, `●`) and the cell after it.
  FocusBar* = "\xE2\x96\x8E"     ## ▎
  RunningGlyph* = "\xE2\x97\x8F" ## ●

type
  ActivityRow = object
    ## One line laid out: the rows it takes.
    line: TimelineLine
    rows: int

proc lineStart(line: TimelineLine): int =
  ## The line's first cell after the focus bar's: its indent.
  1 + line.indent * IndentCells

proc pressOf(press: ActivityPress; operation, target: string): proc() =
  ## A target's press: the operation and its target, handed to `press`. A
  ## proc of its own so each closure owns its pair.
  result = proc() =
    if press != nil: press(operation, target)

proc copyCells(line: TimelineLine): int =
  if line.copyText.len > 0: widthOf(CopyLabel) + 2 else: 0

proc proseRows(line: TimelineLine; cells: int): seq[string] =
  ## A prose line wrapped to `cells`, each of its own lines (an output's,
  ## a diff's) wrapped apart.
  for part in line.text.splitLines:
    if part.len == 0: result.add ""
    else: result.add wrapCells(part, cells)

proc rowsOf(line: TimelineLine; width: int): int =
  ## The rows a line takes at `width` cells.
  if not line.isProse: return 1
  let avail = max(1, width - lineStart(line) - GlyphCells - copyCells(line) - 1)
  max(1, proseRows(line, avail).len)

proc layoutLines(lines: openArray[TimelineLine]; width: int): seq[ActivityRow] =
  for i, line in lines:
    # A blank row sets each turn after the first apart.
    let gap = if line.kind == tlkTurn and i > 0: 1 else: 0
    result.add ActivityRow(line: line, rows: rowsOf(line, width) + gap)

proc firstShown(rows: seq[ActivityRow]; vm: SessionTimelineVM; height: int): int =
  ## The first line drawn: the end's when following, else the anchor's.
  if rows.len == 0: return 0
  if vm.follow.val:
    var used = 0
    var i = rows.high
    while i >= 0 and used + rows[i].rows <= height:
      used += rows[i].rows
      dec i
    return i + 1
  let anchor = vm.anchor
  if anchor.len == 0: return 0
  var at = 0
  for i, r in rows:
    if r.line.id == anchor: at = i
  # A list cannot scroll past its end (as the browser's cannot): when the
  # lines from the anchor on leave rows below them, earlier lines fill them.
  var used = 0
  for i in at ..< rows.len: used += rows[i].rows
  while at > 0 and used + rows[at - 1].rows <= height:
    used += rows[at - 1].rows
    dec at
  at

proc drawParts(c: var AhCanvas; node: AhNode; line: TimelineLine;
               row, col, cells: int) =
  ## A one-row line's parts from `col`: the first part's words, its path
  ## cut in its middle, then each further part one cell after the last; the
  ## first part gives way to the others, which are short (counts, an exit
  ## code), except a running command, which is cut first.
  let rest = line.partsAfterFirst
  var restCells = 0
  for part in rest:
    if part.role != "running": restCells += 1 + widthOf(part.text)
  let first = line.parts[0]
  var at = col
  let firstRoom = max(1, cells - restCells)
  let firstInk = timelineInk(c.p, first.role)
  let bold = first.role == "label"
  if line.path.len > 0:
    let words = line.pathWords
    let wordsShown = elide(words.strip(leading = false), firstRoom)
    at += c.put(row, at, wordsShown, firstInk, bold)
    let pathRoom = max(0, col + firstRoom - at - 1)
    if pathRoom > 0:
      at += 1
      let shown = elidePath(line.path, pathRoom)
      at += c.put(row, at, shown, firstInk, bold)
      discard c.node(node, row, at - widthOf(shown), widthOf(shown), 1,
                     [("path-shown", shown)])
  else:
    let shown = elide(first.text, firstRoom)
    at += c.put(row, at, shown, firstInk, bold)
  for part in rest:
    let room = col + cells - at - 1
    if room <= 0: break
    at += 1
    var shown = part.text
    if part.role == "running":
      discard c.put(row, at, RunningGlyph, timelineInk(c.p, "running"))
      at += 2
      shown = elide(part.text, max(0, room - 2))
    else:
      shown = elide(part.text, room)
    at += c.put(row, at, shown, timelineInk(c.p, part.role))

proc drawLine(c: var AhCanvas; vm: SessionTimelineVM; parent: AhNode;
              line: TimelineLine; row, col, width, height: int;
              press: ActivityPress): int =
  ## One line at `row`; returns the rows it took (at most `height`).
  let start = col + lineStart(line)
  let node = c.node(parent, row, col, width, 1, line.lineFacts)
  if line.focused:
    discard c.put(row, col, FocusBar, c.p.action)
  # The leading glyph: open or closed, a turn's `›`.
  if line.glyph.len > 0:
    discard c.put(row, start, line.glyph, c.p.textCaption)
  elif line.kind == tlkTurn:
    discard c.put(row, start, turnGlyph(), c.p.action)
  let textCol = start + GlyphCells
  let cells = max(1, col + width - textCol - copyCells(line) - 1)
  var used = 1
  if line.isProse:
    let ink = timelineInk(c.p, line.textRole)
    let lines = proseRows(line, cells)
    used = min(height, max(1, lines.len))
    for i in 0 ..< used:
      discard c.put(row + i, textCol, lines[i], ink, line.textRole == "label")
    node.height = used
  else:
    c.drawParts(node, line, row, textCol, cells)
  if line.copyText.len > 0:
    let at = col + width - widthOf(CopyLabel) - 1
    discard c.put(row, at, CopyLabel, c.p.textCaption)
    discard c.node(node, row, at, widthOf(CopyLabel), 1,
                   [("copy-action", CopyLabel), ("operation", ActivityCopyOperation),
                    ("target", line.copyText)])
    c.target(row, at, widthOf(CopyLabel), 1,
             pressOf(press, ActivityCopyOperation, line.copyText))
  if line.expandable:
    # A press anywhere on the line opens or closes it, through the viewmodel.
    let id = line.id
    node.tag("operation", ActivityToggleOperation)
    node.tag("target", id)
    c.target(row, col, max(1, width - copyCells(line)), used,
             pressOf(press, ActivityToggleOperation, id))
  used

proc drawSessionActivity*(c: var AhCanvas; vm: SessionTimelineVM;
                          row, col, width, height: int;
                          press: ActivityPress = nil) =
  ## The timeline at (`row`, `col`), `width` × `height` cells, on the panel's
  ## ground. A press goes to `press`; with none, it runs the carried
  ## operation on the viewmodel (`runActivityPress`, no clipboard).
  let viewModel = vm
  let route: ActivityPress = if press != nil: press
              else: (proc(operation, target: string) =
                       discard viewModel.runActivityPress(operation, target))
  let host = c.node(nil, row, col, width, height,
                    [("surface", "agent-harbor-session-activity"),
                     ("state", stateName(vm.state.val)),
                     ("session-status", vm.statusLabel),
                     ("connection", vm.connection.val)])
  c.area("timeline", row, col, width, height, c.tone.body)
  # The head band: the session's status, and the connection badge.
  c.area("head", row, col, width, 1, c.tone.head)
  let status = vm.statusLabel
  discard c.text(host, row, col + 1, max(1, width - 2), status, c.p.textBody,
                 fact = "status-label")
  let badge = vm.connection.val
  if badge.len > 0:
    let label = " " & badge & " "
    let at = col + width - widthOf(label) - 1
    if at > col + widthOf(status) + 2:
      discard c.put(row, at, label, c.p.textLabel, bg = c.tone.chip)
      discard c.node(host, row, at + 1, widthOf(badge), 1, [("badge", badge)])
  var top = row + 1
  var bodyH = height - 1
  if vm.filter.val.len > 0:
    let text = "Filter: " & vm.filter.val & "  " & vm.filterCountText
    discard c.text(host, top, col + 1, max(1, width - 2), text, c.p.textCaption,
                   fact = "filter")
    inc top
    dec bodyH
  case vm.state.val
  of asIdle, asLoading:
    c.notice(host, top, col, width, bodyH, LoadingNotice, "loading")
    return
  of asError:
    if vm.unresolvable.val.len > 0:
      c.notice(host, top, col, width, bodyH, vm.notice, "unresolvable")
    else:
      c.errorBlock(host, top, col, width, bodyH, ErrorTitle, vm.error.val,
                   pressOf(route, ActivityRetryOperation, ""))
    return
  of asReady:
    discard
  if vm.isEmpty:
    c.notice(host, top, col, width, bodyH, EmptyNotice, "empty")
    return
  let lines = vm.lines
  let rows = layoutLines(lines, width)
  # The strip and the chip take a row each when shown; decide on the rows
  # left for lines, then whether the running line is among those drawn.
  let chip = vm.showsUnseenChip
  let listH = bodyH - (if chip: 1 else: 0)
  let first = firstShown(rows, vm, listH)
  var drawnIds: seq[string]
  var used = 0
  for i in first ..< rows.len:
    if used + 1 > listH: break
    drawnIds.add rows[i].line.id
    used += rows[i].rows
  let runningId = runningLineId(lines, vm.runningLine)
  let strip = runningStripText(vm)
  let showStrip = strip.len > 0 and runningId notin drawnIds
  var r = top
  if showStrip:
    c.area("running-strip", r, col, width, 1, c.tone.playbackBar)
    discard c.put(r, col + 1, RunningGlyph, timelineInk(c.p, "running"))
    discard c.text(host, r, col + 3, max(1, width - 4), strip, c.p.textBody,
                   fact = "running-strip")
    inc r
  let list = c.node(host, r, col, width, top + listH - r, [("lines", $lines.len)])
  for i in first ..< rows.len:
    let left = top + listH - r
    if left <= 0: break
    if rows[i].line.kind == tlkTurn and i > first: inc r
    if top + listH - r <= 0: break
    r += c.drawLine(vm, list, rows[i].line, r, col, width, top + listH - r, route)
  if chip:
    let label = " " & unseenChipText(vm.unseen.val) & " "
    let cr = top + bodyH - 1
    let at = col + max(0, (width - widthOf(label)) div 2)
    let shown = elide(label, width)
    discard c.put(cr, at, shown, c.p.textLabel, bg = c.tone.chip)
    discard c.node(host, cr, at, widthOf(shown), 1,
                   [("unseen", $vm.unseen.val), ("operation", ActivityJumpOperation)])
    c.target(cr, at, widthOf(shown), 1, pressOf(route, ActivityJumpOperation, ""))

proc scrollActivity*(vm: SessionTimelineVM; width, height, delta: int) =
  ## The reader scrolls by `delta` lines (negative: up): the viewmodel
  ## stops following and reads at the new top line; reaching the end
  ## follows again.
  let lines = vm.lines
  if lines.len == 0: return
  let rows = layoutLines(lines, width)
  var at = firstShown(rows, vm, height)
  at = max(0, min(lines.high, at + delta))
  var below = 0
  for i in at ..< rows.len: below += rows[i].rows
  if delta > 0 and below <= height:
    vm.setFollow(true)
    return
  vm.setFollow(false)
  vm.readAt(lines[at].id)
